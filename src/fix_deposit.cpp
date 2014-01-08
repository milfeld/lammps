/* ----------------------------------------------------------------------
   LAMMPS - Large-scale Atomic/Molecular Massively Parallel Simulator
   http://lammps.sandia.gov, Sandia National Laboratories
   Steve Plimpton, sjplimp@sandia.gov

   Copyright (2003) Sandia Corporation.  Under the terms of Contract
   DE-AC04-94AL85000 with Sandia Corporation, the U.S. Government retains
   certain rights in this software.  This software is distributed under
   the GNU General Public License.

   See the README file in the top-level LAMMPS directory.
------------------------------------------------------------------------- */

#include "math.h"
#include "stdlib.h"
#include "string.h"
#include "fix_deposit.h"
#include "atom.h"
#include "atom_vec.h"
#include "molecule.h"
#include "force.h"
#include "update.h"
#include "modify.h"
#include "fix.h"
#include "comm.h"
#include "domain.h"
#include "lattice.h"
#include "region.h"
#include "random_park.h"
#include "math_extra.h"
#include "math_const.h"
#include "memory.h"
#include "error.h"

using namespace LAMMPS_NS;
using namespace FixConst;
using namespace MathConst;

enum{ATOM,MOLECULE};

/* ---------------------------------------------------------------------- */

FixDeposit::FixDeposit(LAMMPS *lmp, int narg, char **arg) :
  Fix(lmp, narg, arg)
{
  if (narg < 7) error->all(FLERR,"Illegal fix deposit command");

  restart_global = 1;
  time_depend = 1;

  // required args

  ninsert = force->inumeric(FLERR,arg[3]);
  ntype = force->inumeric(FLERR,arg[4]);
  nfreq = force->inumeric(FLERR,arg[5]);
  seed = force->inumeric(FLERR,arg[6]);

  if (seed <= 0) error->all(FLERR,"Illegal fix deposit command");

  // read options from end of input line

  options(narg-7,&arg[7]);

  // error checks on region and its extent being inside simulation box

  if (iregion == -1) error->all(FLERR,"Must specify a region in fix deposit");
  if (domain->regions[iregion]->bboxflag == 0)
    error->all(FLERR,"Fix deposit region does not support a bounding box");
  if (domain->regions[iregion]->dynamic_check())
    error->all(FLERR,"Fix deposit region cannot be dynamic");

  xlo = domain->regions[iregion]->extent_xlo;
  xhi = domain->regions[iregion]->extent_xhi;
  ylo = domain->regions[iregion]->extent_ylo;
  yhi = domain->regions[iregion]->extent_yhi;
  zlo = domain->regions[iregion]->extent_zlo;
  zhi = domain->regions[iregion]->extent_zhi;

  if (domain->triclinic == 0) {
    if (xlo < domain->boxlo[0] || xhi > domain->boxhi[0] ||
        ylo < domain->boxlo[1] || yhi > domain->boxhi[1] ||
        zlo < domain->boxlo[2] || zhi > domain->boxhi[2])
      error->all(FLERR,"Deposition region extends outside simulation box");
  } else {
    if (xlo < domain->boxlo_bound[0] || xhi > domain->boxhi_bound[0] ||
        ylo < domain->boxlo_bound[1] || yhi > domain->boxhi_bound[1] ||
        zlo < domain->boxlo_bound[2] || zhi > domain->boxhi_bound[2])
      error->all(FLERR,"Deposition region extends outside simulation box");
  }

  // error check and further setup for mode = MOLECULE

  if (atom->tag_enable == 0)
    error->all(FLERR,"Cannot use fix_deposit unless atoms have IDs");

  if (mode == MOLECULE) {
    if (atom->molecule_flag == 0)
      error->all(FLERR,"Fix deposit requires atom attribute molecule");
    if (onemol->xflag == 0)
      error->all(FLERR,"Fix deposit molecule must have coordinates");
    if (onemol->typeflag == 0)
      error->all(FLERR,"Fix deposit molecule must have atom types");

    // fix deposit uses geoemetric center of molecule for insertion

    onemol->compute_center();
  }

  // setup of coords and imageflags array

  if (mode == ATOM) natom = 1;
  else natom = onemol->natoms;
  memory->create(coords,natom,3,"deposit:coords");
  memory->create(imageflags,natom,"deposit:imageflags");

  // setup scaling

  double xscale,yscale,zscale;
  if (scaleflag) {
    xscale = domain->lattice->xlattice;
    yscale = domain->lattice->ylattice;
    zscale = domain->lattice->zlattice;
  }
  else xscale = yscale = zscale = 1.0;

  // apply scaling to all input parameters with dist/vel units

  if (domain->dimension == 2) {
    lo *= yscale;
    hi *= yscale;
    rate *= yscale;
  } else {
    lo *= zscale;
    hi *= zscale;
    rate *= zscale;
  }
  deltasq *= xscale*xscale;
  nearsq *= xscale*xscale;
  vxlo *= xscale;
  vxhi *= xscale;
  vylo *= yscale;
  vyhi *= yscale;
  vzlo *= zscale;
  vzhi *= zscale;
  tx *= xscale;
  ty *= yscale;
  tz *= zscale;

  // find current max atom and molecule IDs if necessary

  if (idnext) find_maxid();

  // random number generator, same for all procs

  random = new RanPark(lmp,seed);

  // set up reneighboring

  force_reneighbor = 1;
  next_reneighbor = update->ntimestep + 1;
  nfirst = next_reneighbor;
  ninserted = 0;
}

/* ---------------------------------------------------------------------- */

FixDeposit::~FixDeposit()
{
  delete random;
  delete [] idregion;
  memory->destroy(coords);
  memory->destroy(imageflags);
}

/* ---------------------------------------------------------------------- */

int FixDeposit::setmask()
{
  int mask = 0;
  mask |= PRE_EXCHANGE;
  return mask;
}

/* ---------------------------------------------------------------------- */

void FixDeposit::init()
{
  // set index and check validity of region

  iregion = domain->find_region(idregion);
  if (iregion == -1)
    error->all(FLERR,"Region ID for fix deposit does not exist");
}

/* ----------------------------------------------------------------------
   perform particle insertion
------------------------------------------------------------------------- */

void FixDeposit::pre_exchange()
{
  int i,j,m,n;
  int flag,flagall;
  double coord[3],lamda[3],delx,dely,delz,rsq;
  double alpha,beta,gamma;
  double r[3],rotmat[3][3],quat[4];
  double *newcoord;

  // just return if should not be called on this timestep

  if (next_reneighbor != update->ntimestep) return;

  // compute current offset = bottom of insertion volume

  double offset = 0.0;
  if (rateflag) offset = (update->ntimestep - nfirst) * update->dt * rate;

  double *sublo,*subhi;
  if (domain->triclinic == 0) {
    sublo = domain->sublo;
    subhi = domain->subhi;
  } else {
    sublo = domain->sublo_lamda;
    subhi = domain->subhi_lamda;
  }

  // find current max atom and molecule IDs if necessary

  if (!idnext) find_maxid();

  // attempt an insertion until successful

  int dimension = domain->dimension;
  int nfix = modify->nfix;
  Fix **fix = modify->fix;

  int success = 0;
  int attempt = 0;
  while (attempt < maxattempt) {
    attempt++;

    // choose random position for new particle within region

    coord[0] = xlo + random->uniform() * (xhi-xlo);
    coord[1] = ylo + random->uniform() * (yhi-ylo);
    coord[2] = zlo + random->uniform() * (zhi-zlo);
    while (domain->regions[iregion]->match(coord[0],coord[1],coord[2]) == 0) {
      coord[0] = xlo + random->uniform() * (xhi-xlo);
      coord[1] = ylo + random->uniform() * (yhi-ylo);
      coord[2] = zlo + random->uniform() * (zhi-zlo);
    }

    // adjust vertical coord by offset

    if (dimension == 2) coord[1] += offset;
    else coord[2] += offset;

    // if global, reset vertical coord to be lo-hi above highest atom
    // if local, reset vertical coord to be lo-hi above highest "nearby" atom
    // local computation computes lateral distance between 2 particles w/ PBC
    // when done, have final coord of atom or center pt of molecule

    if (globalflag || localflag) {
      int dim;
      double max,maxall,delx,dely,delz,rsq;

      if (dimension == 2) {
        dim = 1;
        max = domain->boxlo[1];
      } else {
        dim = 2;
        max = domain->boxlo[2];
      }

      double **x = atom->x;
      int nlocal = atom->nlocal;
      for (i = 0; i < nlocal; i++) {
        if (localflag) {
          delx = coord[0] - x[i][0];
          dely = coord[1] - x[i][1];
          delz = 0.0;
          domain->minimum_image(delx,dely,delz);
          if (dimension == 2) rsq = delx*delx;
          else rsq = delx*delx + dely*dely;
          if (rsq > deltasq) continue;
        }
        if (x[i][dim] > max) max = x[i][dim];
      }

      MPI_Allreduce(&max,&maxall,1,MPI_DOUBLE,MPI_MAX,world);
      if (dimension == 2)
        coord[1] = maxall + lo + random->uniform()*(hi-lo);
      else
        coord[2] = maxall + lo + random->uniform()*(hi-lo);
    }

    // coords = coords of all atoms
    // for molecule, perform random rotation around center pt
    // apply PBC so final coords are inside box
    // also store image flag modified due to PBC

    if (mode == ATOM) {
      coords[0][0] = coord[0];
      coords[0][1] = coord[1];
      coords[0][2] = coord[2];
    } else {
      if (dimension == 3) {
        r[0] = random->uniform() - 0.5;
        r[1] = random->uniform() - 0.5;
        r[2] = random->uniform() - 0.5;
      } else {
        r[0] = r[1] = 0.0;
        r[2] = 1.0;
      }
      double theta = random->uniform() * MY_2PI;
      MathExtra::norm3(r);
      MathExtra::axisangle_to_quat(r,theta,quat);
      MathExtra::quat_to_mat(quat,rotmat);
      for (i = 0; i < natom; i++) {
        MathExtra::matvec(rotmat,onemol->dx[i],coords[i]);
        coords[i][0] += coord[0];
        coords[i][1] += coord[1];
        coords[i][2] += coord[2];

        imageflags[i] = ((tagint) IMGMAX << IMG2BITS) |
          ((tagint) IMGMAX << IMGBITS) | IMGMAX;
        domain->remap(coords[i],imageflags[i]);
      }
    }

    // if distance to any inserted atom is less than near, try again
    // use minimum_image() to account for PBC

    double **x = atom->x;
    int nlocal = atom->nlocal;

    flag = 0;
    for (m = 0; m < natom; m++) {
      for (i = 0; i < nlocal; i++) {
        delx = coords[m][0] - x[i][0];
        dely = coords[m][1] - x[i][1];
        delz = coords[m][2] - x[i][2];
        domain->minimum_image(delx,dely,delz);
        rsq = delx*delx + dely*dely + delz*delz;
        if (rsq < nearsq) flag = 1;
      }
    }
    MPI_Allreduce(&flag,&flagall,1,MPI_INT,MPI_MAX,world);
    if (flagall) continue;

    // proceed with insertion
    // choose random velocity for new particle
    // used for every atom in molecule

    double vxtmp = vxlo + random->uniform() * (vxhi-vxlo);
    double vytmp = vylo + random->uniform() * (vyhi-vylo);
    double vztmp = vzlo + random->uniform() * (vzhi-vzlo);

    // if target specified, change velocity vector accordingly

    if (targetflag) {
      double vel = sqrt(vxtmp*vxtmp + vytmp*vytmp + vztmp*vztmp);
      delx = tx - coord[0];
      dely = ty - coord[1];
      delz = tz - coord[2];
      double rsq = delx*delx + dely*dely + delz*delz;
      if (rsq > 0.0) {
        double rinv = sqrt(1.0/rsq);
        vxtmp = delx*rinv*vel;
        vytmp = dely*rinv*vel;
        vztmp = delz*rinv*vel;
      }
    }

    // check if new atoms are in my sub-box or above it if I am highest proc
    // if so, add atom to my list via create_atom()
    // initialize additional info about the atoms
    // set group mask to "all" plus fix group

    for (m = 0; m < natom; m++) {
      if (domain->triclinic) {
        domain->x2lamda(coords[m],lamda);
        newcoord = lamda;
      } else newcoord = coords[m];
      
      flag = 0;
      if (newcoord[0] >= sublo[0] && newcoord[0] < subhi[0] &&
          newcoord[1] >= sublo[1] && newcoord[1] < subhi[1] &&
          newcoord[2] >= sublo[2] && newcoord[2] < subhi[2]) flag = 1;
      else if (dimension == 3 && newcoord[2] >= domain->boxhi[2] &&
               comm->myloc[2] == comm->procgrid[2]-1 &&
               newcoord[0] >= sublo[0] && newcoord[0] < subhi[0] &&
               newcoord[1] >= sublo[1] && newcoord[1] < subhi[1]) flag = 1;
      else if (dimension == 2 && newcoord[1] >= domain->boxhi[1] &&
               comm->myloc[1] == comm->procgrid[1]-1 &&
               newcoord[0] >= sublo[0] && newcoord[0] < subhi[0]) flag = 1;

      if (flag) {
        if (mode == ATOM) atom->avec->create_atom(ntype,coords[m]);
        else atom->avec->create_atom(onemol->type[m],coords[m]);
        n = atom->nlocal - 1;
        atom->tag[n] = maxtag_all + m+1;
        if (mode == MOLECULE) atom->molecule[n] = maxmol_all;
        atom->mask[n] = 1 | groupbit;
        atom->image[n] = imageflags[m];
        atom->v[n][0] = vxtmp;
        atom->v[n][1] = vytmp;
        atom->v[n][2] = vztmp;
        if (mode == MOLECULE) atom->add_molecule_atom(onemol,m,n,maxtag_all);
        for (j = 0; j < nfix; j++)
          if (fix[j]->create_attribute) fix[j]->set_arrays(n);
      }
    }

    // old code: unsuccessful if no proc performed insertion of an atom
    // don't think that check is necessary
    // if get this far, should always be succesful
    // would be hard to undo partial insertion for a molecule
    // better to check how many atoms could be inserted (w/out inserting)
    //   then sum to insure all are inserted, before doing actual insertion
    // MPI_Allreduce(&flag,&success,1,MPI_INT,MPI_MAX,world);

    success = 1;
    break;
  }

  // warn if not successful b/c too many attempts

  if (!success && comm->me == 0)
    error->warning(FLERR,"Particle deposition was unsuccessful",0);

  // reset global natoms,nbonds,etc
  // increment maxtag_all and maxmol_all if necessary
  // if global map exists, reset it now instead of waiting for comm
  // since adding atoms messes up ghosts

  if (success) {
    atom->natoms += natom;
    if (mode == MOLECULE) {
      atom->nbonds += onemol->nbonds;
      atom->nangles += onemol->nangles;
      atom->ndihedrals += onemol->ndihedrals;
      atom->nimpropers += onemol->nimpropers;
    }
    if (idnext) {
      maxtag_all += natom;
      if (mode == MOLECULE) maxmol_all++;
    }
    if (atom->map_style) {
      atom->nghost = 0;
      atom->map_init();
      atom->map_set();
    }
  }

  // next timestep to insert
  // next_reneighbor = 0 if done

  if (success) ninserted++;
  if (ninserted < ninsert) next_reneighbor += nfreq;
  else next_reneighbor = 0;
}

/* ----------------------------------------------------------------------
   maxtag_all = current max atom ID for all atoms
   maxmol_all = current max molecule ID for all atoms
------------------------------------------------------------------------- */

void FixDeposit::find_maxid()
{
  int *tag = atom->tag;
  int *molecule = atom->molecule;
  int nlocal = atom->nlocal;

  int max = 0;
  for (int i = 0; i < nlocal; i++) max = MAX(max,tag[i]);
  MPI_Allreduce(&max,&maxtag_all,1,MPI_INT,MPI_MAX,world);

  if (mode == MOLECULE) {
    max = 0;
    for (int i = 0; i < nlocal; i++) max = MAX(max,molecule[i]);
    MPI_Allreduce(&max,&maxmol_all,1,MPI_INT,MPI_MAX,world);
  }
}

/* ----------------------------------------------------------------------
   parse optional parameters at end of input line
------------------------------------------------------------------------- */

void FixDeposit::options(int narg, char **arg)
{
  // defaults

  iregion = -1;
  idregion = NULL;
  mode = ATOM;
  idnext = 0;
  globalflag = localflag = 0;
  lo = hi = deltasq = 0.0;
  nearsq = 0.0;
  maxattempt = 10;
  rateflag = 0;
  vxlo = vxhi = vylo = vyhi = vzlo = vzhi = 0.0;
  scaleflag = 1;
  targetflag = 0;

  int iarg = 0;
  while (iarg < narg) {
    if (strcmp(arg[iarg],"region") == 0) {
      if (iarg+2 > narg) error->all(FLERR,"Illegal fix deposit command");
      iregion = domain->find_region(arg[iarg+1]);
      if (iregion == -1)
        error->all(FLERR,"Region ID for fix deposit does not exist");
      int n = strlen(arg[iarg+1]) + 1;
      idregion = new char[n];
      strcpy(idregion,arg[iarg+1]);
      iarg += 2;
    } else if (strcmp(arg[iarg],"mol") == 0) {
      if (iarg+2 > narg) error->all(FLERR,"Illegal fix deposit command");
      int imol = atom->find_molecule(arg[iarg+1]);
      if (imol == -1)
        error->all(FLERR,"Molecule ID for fix deposit does not exist");
      mode = MOLECULE;
      onemol = atom->molecules[imol];
     iarg += 2;
    } else if (strcmp(arg[iarg],"id") == 0) {
      if (iarg+2 > narg) error->all(FLERR,"Illegal fix deposit command");
      if (strcmp(arg[iarg+1],"max") == 0) idnext = 0;
      else if (strcmp(arg[iarg+1],"next") == 0) idnext = 1;
      else error->all(FLERR,"Illegal fix deposit command");
      iarg += 2;
    } else if (strcmp(arg[iarg],"global") == 0) {
      if (iarg+3 > narg) error->all(FLERR,"Illegal fix deposit command");
      globalflag = 1;
      localflag = 0;
      lo = force->numeric(FLERR,arg[iarg+1]);
      hi = force->numeric(FLERR,arg[iarg+2]);
      iarg += 3;
    } else if (strcmp(arg[iarg],"local") == 0) {
      if (iarg+4 > narg) error->all(FLERR,"Illegal fix deposit command");
      localflag = 1;
      globalflag = 0;
      lo = force->numeric(FLERR,arg[iarg+1]);
      hi = force->numeric(FLERR,arg[iarg+2]);
      deltasq = force->numeric(FLERR,arg[iarg+3]) * 
        force->numeric(FLERR,arg[iarg+3]);
      iarg += 4;
    } else if (strcmp(arg[iarg],"near") == 0) {
      if (iarg+2 > narg) error->all(FLERR,"Illegal fix deposit command");
      nearsq = force->numeric(FLERR,arg[iarg+1]) * 
        force->numeric(FLERR,arg[iarg+1]);
      iarg += 2;
    } else if (strcmp(arg[iarg],"attempt") == 0) {
      if (iarg+2 > narg) error->all(FLERR,"Illegal fix deposit command");
      maxattempt = force->inumeric(FLERR,arg[iarg+1]);
      iarg += 2;
    } else if (strcmp(arg[iarg],"rate") == 0) {
      if (iarg+2 > narg) error->all(FLERR,"Illegal fix deposit command");
      rateflag = 1;
      rate = force->numeric(FLERR,arg[iarg+1]);
      iarg += 2;
    } else if (strcmp(arg[iarg],"vx") == 0) {
      if (iarg+3 > narg) error->all(FLERR,"Illegal fix deposit command");
      vxlo = force->numeric(FLERR,arg[iarg+1]);
      vxhi = force->numeric(FLERR,arg[iarg+2]);
      iarg += 3;
    } else if (strcmp(arg[iarg],"vy") == 0) {
      if (iarg+3 > narg) error->all(FLERR,"Illegal fix deposit command");
      vylo = force->numeric(FLERR,arg[iarg+1]);
      vyhi = force->numeric(FLERR,arg[iarg+2]);
      iarg += 3;
    } else if (strcmp(arg[iarg],"vz") == 0) {
      if (iarg+3 > narg) error->all(FLERR,"Illegal fix deposit command");
      vzlo = force->numeric(FLERR,arg[iarg+1]);
      vzhi = force->numeric(FLERR,arg[iarg+2]);
      iarg += 3;
    } else if (strcmp(arg[iarg],"units") == 0) {
      if (iarg+2 > narg) error->all(FLERR,"Illegal fix deposit command");
      if (strcmp(arg[iarg+1],"box") == 0) scaleflag = 0;
      else if (strcmp(arg[iarg+1],"lattice") == 0) scaleflag = 1;
      else error->all(FLERR,"Illegal fix deposit command");
      iarg += 2;
    } else if (strcmp(arg[iarg],"target") == 0) {
      if (iarg+4 > narg) error->all(FLERR,"Illegal fix deposit command");
      tx = force->numeric(FLERR,arg[iarg+1]);
      ty = force->numeric(FLERR,arg[iarg+2]);
      tz = force->numeric(FLERR,arg[iarg+3]);
      targetflag = 1;
      iarg += 4;
    } else error->all(FLERR,"Illegal fix deposit command");
  }
}

/* ----------------------------------------------------------------------
   pack entire state of Fix into one write
------------------------------------------------------------------------- */

void FixDeposit::write_restart(FILE *fp)
{
  int n = 0;
  double list[4];
  list[n++] = random->state();
  list[n++] = ninserted;
  list[n++] = nfirst;
  list[n++] = next_reneighbor;

  if (comm->me == 0) {
    int size = n * sizeof(double);
    fwrite(&size,sizeof(int),1,fp);
    fwrite(list,sizeof(double),n,fp);
  }
}

/* ----------------------------------------------------------------------
   use state info from restart file to restart the Fix
------------------------------------------------------------------------- */

void FixDeposit::restart(char *buf)
{
  int n = 0;
  double *list = (double *) buf;

  seed = static_cast<int> (list[n++]);
  ninserted = static_cast<int> (list[n++]);
  nfirst = static_cast<int> (list[n++]);
  next_reneighbor = static_cast<int> (list[n++]);

  random->reset(seed);
}
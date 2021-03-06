// **************************************************************************
//                                 tersoff.cu
//                             -------------------
//                              Trung Dac Nguyen
//
//  Device code for acceleration of the tersoff pair style
//
// __________________________________________________________________________
//    This file is part of the LAMMPS Accelerator Library (LAMMPS_AL)
// __________________________________________________________________________
//
//       begin                : Thu April 17, 2014
//       email                : ndactrung@gmail.com
// ***************************************************************************/

#define THREE_CONCURRENT

#ifdef NV_KERNEL
#include "lal_tersoff_extra.h"

#ifndef _DOUBLE_DOUBLE
texture<float4> pos_tex;
texture<float4> ts1_tex;
texture<float4> ts2_tex;
texture<float4> ts3_tex;
texture<float4> ts4_tex;
texture<float4> ts5_tex;
texture<float> zeta_tex;
#else
texture<int4,1> pos_tex;
texture<int4> ts1_tex;
texture<int4> ts2_tex;
texture<int4> ts3_tex;
texture<int4> ts4_tex;
texture<int4> ts5_tex;
texture<int2> zeta_tex;
#endif

#else
#define pos_tex x_
#define ts1_tex ts1
#define ts2_tex ts2
#define ts3_tex ts3
#define ts4_tex ts4
#define ts5_tex ts5
#define zeta_tex zetaij
#endif

#define THIRD (numtyp)0.66666667

#if (ARCH < 300)

#define store_answers_p(f, energy, virial, ii, inum, tid, t_per_atom, offset, \
                      eflag, vflag, ans, engv)                              \
  if (t_per_atom>1) {                                                       \
    __local acctyp red_acc[6][BLOCK_ELLIPSE];                               \
    red_acc[0][tid]=f.x;                                                    \
    red_acc[1][tid]=f.y;                                                    \
    red_acc[2][tid]=f.z;                                                    \
    red_acc[3][tid]=energy;                                                 \
    for (unsigned int s=t_per_atom/2; s>0; s>>=1) {                         \
      if (offset < s) {                                                     \
        for (int r=0; r<4; r++)                                             \
          red_acc[r][tid] += red_acc[r][tid+s];                             \
      }                                                                     \
    }                                                                       \
    f.x=red_acc[0][tid];                                                    \
    f.y=red_acc[1][tid];                                                    \
    f.z=red_acc[2][tid];                                                    \
    energy=red_acc[3][tid];                                                 \
    if (vflag>0) {                                                          \
      for (int r=0; r<6; r++)                                               \
        red_acc[r][tid]=virial[r];                                          \
      for (unsigned int s=t_per_atom/2; s>0; s>>=1) {                       \
        if (offset < s) {                                                   \
          for (int r=0; r<6; r++)                                           \
            red_acc[r][tid] += red_acc[r][tid+s];                           \
        }                                                                   \
      }                                                                     \
      for (int r=0; r<6; r++)                                               \
        virial[r]=red_acc[r][tid];                                          \
    }                                                                       \
  }                                                                         \
  if (offset==0) {                                                          \
    int ei=ii;                                                              \
    if (eflag>0) {                                                          \
      engv[ei]+=energy*(acctyp)0.5;                                         \
      ei+=inum;                                                             \
    }                                                                       \
    if (vflag>0) {                                                          \
      for (int i=0; i<6; i++) {                                             \
        engv[ei]+=virial[i]*(acctyp)0.5;                                    \
        ei+=inum;                                                           \
      }                                                                     \
    }                                                                       \
    acctyp4 old=ans[ii];                                                    \
    old.x+=f.x;                                                             \
    old.y+=f.y;                                                             \
    old.z+=f.z;                                                             \
    ans[ii]=old;                                                            \
  }

#else

#define store_answers_p(f, energy, virial, ii, inum, tid, t_per_atom, offset, \
                      eflag, vflag, ans, engv)                              \
  if (t_per_atom>1) {                                                       \
    for (unsigned int s=t_per_atom/2; s>0; s>>=1) {                         \
        f.x += shfl_xor(f.x, s, t_per_atom);                                \
        f.y += shfl_xor(f.y, s, t_per_atom);                                \
        f.z += shfl_xor(f.z, s, t_per_atom);                                \
        energy += shfl_xor(energy, s, t_per_atom);                          \
    }                                                                       \
    if (vflag>0) {                                                          \
      for (unsigned int s=t_per_atom/2; s>0; s>>=1) {                       \
          for (int r=0; r<6; r++)                                           \
            virial[r] += shfl_xor(virial[r], s, t_per_atom);                \
      }                                                                     \
    }                                                                       \
  }                                                                         \
  if (offset==0) {                                                          \
    int ei=ii;                                                              \
    if (eflag>0) {                                                          \
      engv[ei]+=energy*(acctyp)0.5;                                         \
      ei+=inum;                                                             \
    }                                                                       \
    if (vflag>0) {                                                          \
      for (int i=0; i<6; i++) {                                             \
        engv[ei]+=virial[i]*(acctyp)0.5;                                    \
        ei+=inum;                                                           \
      }                                                                     \
    }                                                                       \
    acctyp4 old=ans[ii];                                                    \
    old.x+=f.x;                                                             \
    old.y+=f.y;                                                             \
    old.z+=f.z;                                                             \
    ans[ii]=old;                                                            \
  }

#endif

// Tersoff is currently used for 3 elements at most: 3*3*3 = 27 entries
// while the block size should never be less than 32.
// SHARED_SIZE = 32 for now to reduce the pressure on the shared memory per block
// must be increased if there will be more than 3 elements in the future.
#define SHARED_SIZE 32

__kernel void k_tersoff_zeta(const __global numtyp4 *restrict x_,
                             const __global numtyp4 *restrict ts1_in,
                             const __global numtyp4 *restrict ts2_in,
                             const __global numtyp4 *restrict ts4_in,
                             const __global numtyp *restrict cutsq,
                             const __global int *restrict map,
                             const __global int *restrict elem2param,
                             const int nelements, const int nparams,
                             __global numtyp * zetaij,
                             const __global int * dev_nbor, 
                             const __global int * dev_packed, 
                             const int nall, const int inum,
                             const int nbor_pitch, const int t_per_atom) {
  __local int tpa_sq,n_stride;
  tpa_sq = fast_mul(t_per_atom,t_per_atom);

  int tid, ii, offset;
  atom_info(tpa_sq,ii,tid,offset);
  
  // must be increased if there will be more than 3 elements in the future.
  __local numtyp4 ts1[SHARED_SIZE];
  __local numtyp4 ts2[SHARED_SIZE];
  __local numtyp4 ts4[SHARED_SIZE];
  if (tid<nparams) {
    ts1[tid]=ts1_in[tid];
    ts2[tid]=ts2_in[tid];
    ts4[tid]=ts4_in[tid];
  }

  __syncthreads();

  if (ii<nall) {
    int nbor_j, nbor_end;
    int i, numj;

    int offset_j=offset/t_per_atom;
    nbor_info(dev_nbor,dev_packed,nbor_pitch,t_per_atom,ii,offset_j,i,numj,
              n_stride,nbor_end,nbor_j);
    int offset_k=tid & (t_per_atom-1);
    int nborj_start = nbor_j;

    numtyp4 ix; fetch4(ix,i,pos_tex); //x_[i];
    int itype=ix.w;
    itype=map[itype];

    for ( ; nbor_j<nbor_end; nbor_j+=n_stride) {
  
      int j=dev_packed[nbor_j];
      j &= NEIGHMASK;

      numtyp4 jx; fetch4(jx,j,pos_tex); //x_[j];
      int jtype=jx.w;
      jtype=map[jtype];

      // Compute rij
      numtyp4 delr1, delr2;
      delr1.x = jx.x-ix.x;
      delr1.y = jx.y-ix.y;
      delr1.z = jx.z-ix.z;
      numtyp rsq1 = delr1.x*delr1.x+delr1.y*delr1.y+delr1.z*delr1.z;

      int ijparam=elem2param[itype*nelements*nelements+jtype*nelements+jtype];      
      if (rsq1 > cutsq[ijparam]) continue;
      
      // compute zeta_ij
      numtyp z = (numtyp)0;
      int nbor_k = nborj_start-offset_j+offset_k;
      for ( ; nbor_k < nbor_end; nbor_k+=n_stride) { 
        int k=dev_packed[nbor_k];
        k &= NEIGHMASK;
        
        if (k == j) continue;
        
        numtyp4 kx; fetch4(kx,k,pos_tex); //x_[k];
        int ktype=kx.w;
        ktype=map[ktype];
           
        // Compute rik
        delr2.x = kx.x-ix.x;
        delr2.y = kx.y-ix.y;
        delr2.z = kx.z-ix.z;
        numtyp rsq2 = delr2.x*delr2.x+delr2.y*delr2.y+delr2.z*delr2.z;
     
        int ijkparam=elem2param[itype*nelements*nelements+jtype*nelements+ktype];   
        if (rsq2 > cutsq[ijkparam]) continue;
        
        numtyp4 ts1_ijkparam = ts1[ijkparam]; //fetch4(ts1_ijkparam,ijkparam,ts1_tex);
        numtyp ijkparam_lam3 = ts1_ijkparam.z;
        numtyp ijkparam_powermint = ts1_ijkparam.w;
        numtyp4 ts2_ijkparam = ts2[ijkparam]; //fetch4(ts2_ijkparam,ijkparam,ts2_tex);
        numtyp ijkparam_bigr = ts2_ijkparam.z;
        numtyp ijkparam_bigd = ts2_ijkparam.w;
        numtyp4 ts4_ijkparam = ts4[ijkparam]; //fetch4(ts4_ijkparam,ijkparam,ts4_tex);
        numtyp ijkparam_c = ts4_ijkparam.x;
        numtyp ijkparam_d = ts4_ijkparam.y;
        numtyp ijkparam_h = ts4_ijkparam.z;
        numtyp ijkparam_gamma = ts4_ijkparam.w;  
        z += zeta(ijkparam_powermint, ijkparam_lam3, ijkparam_bigr, ijkparam_bigd,
                  ijkparam_c, ijkparam_d, ijkparam_h, ijkparam_gamma,
                  rsq1, rsq2, delr1, delr2);
      }

      int jj = (nbor_j-offset_j-2*nbor_pitch)/n_stride;  
      int idx = jj*n_stride + i*t_per_atom + offset_j;
      zetaij[idx] = z;
    } // for nbor

  } // if ii
}

__kernel void k_tersoff_repulsive(const __global numtyp4 *restrict x_,
                                  const __global numtyp4 *restrict ts1_in,
                                  const __global numtyp4 *restrict ts2_in,
                                  const __global numtyp *restrict cutsq,
                                  const __global int *restrict map,
                                  const __global int *restrict elem2param,
                                  const int nelements, const int nparams,
                                  const __global int * dev_nbor, 
                                  const __global int * dev_packed, 
                                  __global acctyp4 *restrict ans, 
                                  __global acctyp *restrict engv, 
                                  const int eflag, const int vflag, 
                                  const int inum, const int nbor_pitch, 
                                  const int t_per_atom) {
  __local int n_stride;
  int tid, ii, offset;
  atom_info(t_per_atom,ii,tid,offset);

  __local numtyp4 ts1[SHARED_SIZE];
  __local numtyp4 ts2[SHARED_SIZE];
  if (tid<nparams) {
    ts1[tid]=ts1_in[tid];
    ts2[tid]=ts2_in[tid];
  }

  acctyp energy=(acctyp)0;
  acctyp4 f;
  f.x=(acctyp)0; f.y=(acctyp)0; f.z=(acctyp)0;
  acctyp virial[6];
  for (int i=0; i<6; i++)
    virial[i]=(acctyp)0;

  __syncthreads();

  if (ii<inum) {
    int nbor, nbor_end;
    int i, numj;
    nbor_info(dev_nbor,dev_packed,nbor_pitch,t_per_atom,ii,offset,i,numj,
              n_stride,nbor_end,nbor);

    numtyp4 ix; fetch4(ix,i,pos_tex); //x_[i];
    int itype=ix.w;
    itype=map[itype];
    
    for ( ; nbor<nbor_end; nbor+=n_stride) {
  
      int j=dev_packed[nbor];
      j &= NEIGHMASK;

      numtyp4 jx; fetch4(jx,j,pos_tex); //x_[j];
      int jtype=jx.w;
      jtype=map[jtype];

      int ijparam=elem2param[itype*nelements*nelements+jtype*nelements+jtype];

      // Compute r12

      numtyp delx = ix.x-jx.x;
      numtyp dely = ix.y-jx.y;
      numtyp delz = ix.z-jx.z;
      numtyp rsq = delx*delx+dely*dely+delz*delz;

      if (rsq<cutsq[ijparam]) {
        numtyp feng[2];
        numtyp ijparam_lam1 = ts1[ijparam].x;
        numtyp4 ts2_ijparam = ts2[ijparam];
        numtyp ijparam_biga = ts2_ijparam.x;
        numtyp ijparam_bigr = ts2_ijparam.z;
        numtyp ijparam_bigd = ts2_ijparam.w;

        repulsive(ijparam_bigr, ijparam_bigd, ijparam_lam1, ijparam_biga, 
                  rsq, eflag, feng);

        numtyp force = feng[0];
        f.x+=delx*force;
        f.y+=dely*force;
        f.z+=delz*force;

        if (eflag>0) 
          energy+=feng[1]; 
        if (vflag>0) {
          virial[0] += delx*delx*force;
          virial[1] += dely*dely*force;
          virial[2] += delz*delz*force;
          virial[3] += delx*dely*force;
          virial[4] += delx*delz*force;
          virial[5] += dely*delz*force;
        }
      }
    } // for nbor

    store_answers(f,energy,virial,ii,inum,tid,t_per_atom,offset,eflag,vflag,
                  ans,engv);
  } // if ii

}

__kernel void k_tersoff_three_center(const __global numtyp4 *restrict x_, 
                                     const __global numtyp4 *restrict ts1_in,
                                     const __global numtyp4 *restrict ts2_in,
                                     const __global numtyp4 *restrict ts3_in,
                                     const __global numtyp4 *restrict ts4_in,
                                     const __global numtyp4 *restrict ts5_in,
                                     const __global numtyp *restrict cutsq,
                                     const __global int *restrict map,
                                     const __global int *restrict elem2param,
                                     const int nelements, const int nparams,
                                     const __global numtyp *restrict zetaij,
                                     const __global int * dev_nbor, 
                                     const __global int * dev_packed, 
                                     __global acctyp4 *restrict ans, 
                                     __global acctyp *restrict engv, 
                                     const int eflag, const int vflag, 
                                     const int inum,  const int nbor_pitch, 
                                     const int t_per_atom, const int evatom) {
  __local int tpa_sq, n_stride;
  tpa_sq=fast_mul(t_per_atom,t_per_atom);

  int tid, ii, offset;
  atom_info(tpa_sq,ii,tid,offset); // offset ranges from 0 to tpa_sq-1

  __local numtyp4 ts1[SHARED_SIZE];
  __local numtyp4 ts2[SHARED_SIZE];
  __local numtyp4 ts3[SHARED_SIZE];
  __local numtyp4 ts4[SHARED_SIZE];
  __local numtyp4 ts5[SHARED_SIZE];
  if (tid<nparams) {
    ts1[tid]=ts1_in[tid];
    ts2[tid]=ts2_in[tid];
    ts3[tid]=ts3_in[tid];
    ts4[tid]=ts4_in[tid];
    ts5[tid]=ts5_in[tid];
  }

  acctyp energy=(acctyp)0;
  acctyp4 f;
  f.x=(acctyp)0; f.y=(acctyp)0; f.z=(acctyp)0;
  acctyp virial[6];
  for (int i=0; i<6; i++)
    virial[i]=(acctyp)0;

  __syncthreads();
  
  if (ii<inum) {
    int i, numj, nbor_j, nbor_end;

    int offset_j=offset/t_per_atom;
    nbor_info(dev_nbor,dev_packed,nbor_pitch,t_per_atom,ii,offset_j,i,numj,
              n_stride,nbor_end,nbor_j);
    int offset_k=tid & (t_per_atom-1);
    int nborj_start = nbor_j;

    numtyp4 ix; fetch4(ix,i,pos_tex); //x_[i];
    int itype=ix.w; 
    itype=map[itype];

    for ( ; nbor_j<nbor_end; nbor_j+=n_stride) {
  
      int j=dev_packed[nbor_j];
      j &= NEIGHMASK;

      numtyp4 jx; fetch4(jx,j,pos_tex); //x_[j];
      int jtype=jx.w;
      jtype=map[jtype];

      // Compute r12
      numtyp delr1[3];
      delr1[0] = jx.x-ix.x;
      delr1[1] = jx.y-ix.y;
      delr1[2] = jx.z-ix.z;
      numtyp rsq1 = delr1[0]*delr1[0] + delr1[1]*delr1[1] + delr1[2]*delr1[2];

      int ijparam=elem2param[itype*nelements*nelements+jtype*nelements+jtype];
      if (rsq1 > cutsq[ijparam]) continue;
      numtyp r1 = ucl_sqrt(rsq1);
      numtyp r1inv = ucl_recip(r1);
    
      // look up for zeta_ij

      int jj = (nbor_j-offset_j-2*nbor_pitch) / n_stride; 
      int idx = jj*n_stride + i*t_per_atom + offset_j;
      numtyp zeta_ij = (numtyp)0;
      fetch(zeta_ij,idx,zeta_tex); // zeta_ij = zetaij[idx];

      numtyp fpfeng[4];
      {
      numtyp4 ts1_ijparam = ts1[ijparam]; //fetch4(ts1_ijparam,ijparam,ts1_tex);
      numtyp ijparam_lam2 = ts1_ijparam.y;         
      numtyp4 ts2_ijparam = ts2[ijparam]; //fetch4(ts2_ijparam,ijparam,ts2_tex);
      numtyp ijparam_bigb = ts2_ijparam.y;
      numtyp ijparam_bigr = ts2_ijparam.z;
      numtyp ijparam_bigd = ts2_ijparam.w;
      numtyp4 ts3_ijparam = ts3[ijparam]; //fetch4(ts3_ijparam,ijparam,ts3_tex);
      numtyp ijparam_c1 = ts3_ijparam.x;
      numtyp ijparam_c2 = ts3_ijparam.y;
      numtyp ijparam_c3 = ts3_ijparam.z;
      numtyp ijparam_c4 = ts3_ijparam.w;
      numtyp4 ts5_ijparam = ts5[ijparam]; //fetch4(ts5_ijparam,ijparam,ts5_tex);
      numtyp ijparam_beta = ts5_ijparam.x;
      numtyp ijparam_powern = ts5_ijparam.y;
      force_zeta(ijparam_bigb, ijparam_bigr, ijparam_bigd, ijparam_lam2,
                 ijparam_beta, ijparam_powern, ijparam_c1, ijparam_c2, ijparam_c3,
                 ijparam_c4, rsq1, zeta_ij, eflag, fpfeng);
      }
      numtyp force = fpfeng[0];
      f.x += delr1[0]*force;
      f.y += delr1[1]*force;
      f.z += delr1[2]*force;
      numtyp prefactor = fpfeng[1];

      if (eflag>0) {
        energy+=fpfeng[2];
      }
      if (vflag>0) {
        numtyp mforce = -force;
        virial[0] += delr1[0]*delr1[0]*mforce;
        virial[1] += delr1[1]*delr1[1]*mforce;
        virial[2] += delr1[2]*delr1[2]*mforce;
        virial[3] += delr1[0]*delr1[1]*mforce;
        virial[4] += delr1[0]*delr1[2]*mforce;
        virial[5] += delr1[1]*delr1[2]*mforce;
      }

      int nbor_k=nborj_start-offset_j+offset_k;
      for ( ; nbor_k<nbor_end; nbor_k+=n_stride) {
        int k=dev_packed[nbor_k];
        k &= NEIGHMASK;

        if (j == k) continue;

        numtyp4 kx; fetch4(kx,k,pos_tex);
        int ktype=kx.w;
        ktype=map[ktype];

        numtyp delr2[3];
        delr2[0] = kx.x-ix.x;
        delr2[1] = kx.y-ix.y;
        delr2[2] = kx.z-ix.z;
        numtyp rsq2 = delr2[0]*delr2[0] + delr2[1]*delr2[1] + delr2[2]*delr2[2];

        int ijkparam=elem2param[itype*nelements*nelements+jtype*nelements+ktype];
        if (rsq2 > cutsq[ijkparam]) continue;
        numtyp r2 = ucl_sqrt(rsq2);
        numtyp r2inv = ucl_recip(r2);

        numtyp fi[3], fj[3], fk[3];
        {
        numtyp4 ts1_ijkparam = ts1[ijkparam]; //fetch4(ts1_ijkparam,ijkparam,ts1_tex);
        numtyp ijkparam_lam3 = ts1_ijkparam.z;
        numtyp ijkparam_powermint = ts1_ijkparam.w;
        numtyp4 ts2_ijkparam = ts2[ijkparam]; //fetch4(ts2_ijkparam,ijkparam,ts2_tex);
        numtyp ijkparam_bigr = ts2_ijkparam.z;
        numtyp ijkparam_bigd = ts2_ijkparam.w;
        numtyp4 ts4_ijkparam = ts4[ijkparam]; //fetch4(ts4_ijkparam,ijkparam,ts4_tex);
        numtyp ijkparam_c = ts4_ijkparam.x;
        numtyp ijkparam_d = ts4_ijkparam.y;
        numtyp ijkparam_h = ts4_ijkparam.z;
        numtyp ijkparam_gamma = ts4_ijkparam.w;
        if (vflag>0) 
          attractive(ijkparam_bigr, ijkparam_bigd, ijkparam_powermint,
                     ijkparam_lam3, ijkparam_c, ijkparam_d, ijkparam_h, 
                     ijkparam_gamma, prefactor, r1, r1inv, r2, r2inv, delr1, delr2,
                     fi, fj, fk);
        else 
          attractive_fi(ijkparam_bigr, ijkparam_bigd, ijkparam_powermint,
                        ijkparam_lam3, ijkparam_c, ijkparam_d, ijkparam_h, 
                        ijkparam_gamma, prefactor, r1, r1inv, r2, r2inv, delr1, delr2,
                        fi);
        }
        f.x += fi[0];
        f.y += fi[1];
        f.z += fi[2];

        if (vflag>0) {
          acctyp v[6];
          numtyp pre = (numtyp)2.0;
          if (evatom==1) pre = THIRD;
          v[0] = pre*(delr1[0]*fj[0] + delr2[0]*fk[0]);
          v[1] = pre*(delr1[1]*fj[1] + delr2[1]*fk[1]);
          v[2] = pre*(delr1[2]*fj[2] + delr2[2]*fk[2]);
          v[3] = pre*(delr1[0]*fj[1] + delr2[0]*fk[1]);
          v[4] = pre*(delr1[0]*fj[2] + delr2[0]*fk[2]);
          v[5] = pre*(delr1[1]*fj[2] + delr2[1]*fk[2]);

          virial[0] += v[0]; virial[1] += v[1]; virial[2] += v[2];
          virial[3] += v[3]; virial[4] += v[4]; virial[5] += v[5];
        }
      } // nbor_k
    } // for nbor_j

    store_answers_p(f,energy,virial,ii,inum,tid,t_per_atom,
                     offset,eflag,vflag,ans,engv);
  } // if ii
}

__kernel void k_tersoff_three_end(const __global numtyp4 *restrict x_, 
                                  const __global numtyp4 *restrict ts1_in,
                                  const __global numtyp4 *restrict ts2_in,
                                  const __global numtyp4 *restrict ts3_in,
                                  const __global numtyp4 *restrict ts4_in,
                                  const __global numtyp4 *restrict ts5_in,
                                  const __global numtyp *restrict cutsq,
                                  const __global int *restrict map,
                                  const __global int *restrict elem2param,
                                  const int nelements, const int nparams,
                                  const __global numtyp *restrict zetaij,
                                  const __global int * dev_nbor, 
                                  const __global int * dev_packed, 
                                  __global acctyp4 *restrict ans, 
                                  __global acctyp *restrict engv, 
                                  const int eflag, const int vflag, 
                                  const int inum,  const int nbor_pitch, 
                                  const int t_per_atom) {
  __local int tpa_sq, n_stride;
  tpa_sq=fast_mul(t_per_atom,t_per_atom);

  int tid, ii, offset;
  atom_info(tpa_sq,ii,tid,offset);

  __local numtyp4 ts1[SHARED_SIZE];
  __local numtyp4 ts2[SHARED_SIZE];
  __local numtyp4 ts3[SHARED_SIZE];
  __local numtyp4 ts4[SHARED_SIZE];
  __local numtyp4 ts5[SHARED_SIZE];
  if (tid<nparams) {
    ts1[tid]=ts1_in[tid];
    ts2[tid]=ts2_in[tid];
    ts3[tid]=ts3_in[tid];
    ts4[tid]=ts4_in[tid];
    ts5[tid]=ts5_in[tid];
  }
  
  acctyp energy=(acctyp)0;
  acctyp4 f;
  f.x=(acctyp)0; f.y=(acctyp)0; f.z=(acctyp)0;
  acctyp virial[6];
  for (int i=0; i<6; i++)
    virial[i]=(acctyp)0;

  __syncthreads();
  
  if (ii<inum) {
    int i, numj, nbor_j, nbor_end, k_end;

    int offset_j=offset/t_per_atom;
    nbor_info(dev_nbor,dev_packed,nbor_pitch,t_per_atom,ii,offset_j,i,numj,
              n_stride,nbor_end,nbor_j);
    int offset_k=tid & (t_per_atom-1);
    int nborj_start = nbor_j;

    numtyp4 ix; fetch4(ix,i,pos_tex); //x_[i];
    int itype=ix.w; 
    itype=map[itype];

    for ( ; nbor_j<nbor_end; nbor_j+=n_stride) {
  
      int j=dev_packed[nbor_j];
      j &= NEIGHMASK;

      numtyp4 jx; fetch4(jx,j,pos_tex); //x_[j];
      int jtype=jx.w;
      jtype=map[jtype];

      // Compute r12
      numtyp delr1[3];
      delr1[0] = jx.x-ix.x;
      delr1[1] = jx.y-ix.y;
      delr1[2] = jx.z-ix.z;
      numtyp rsq1 = delr1[0]*delr1[0] + delr1[1]*delr1[1] + delr1[2]*delr1[2];

      int ijparam=elem2param[itype*nelements*nelements+jtype*nelements+jtype];
      if (rsq1 > cutsq[ijparam]) continue;
      numtyp r1 = ucl_sqrt(rsq1);
      numtyp r1inv = ucl_recip(r1);

      numtyp mdelr1[3];
      mdelr1[0] = -delr1[0];
      mdelr1[1] = -delr1[1];
      mdelr1[2] = -delr1[2];

      int nbor_k=j+nbor_pitch;
      int numk=dev_nbor[nbor_k]; 
      if (dev_nbor==dev_packed) {
        nbor_k+=nbor_pitch+fast_mul(j,t_per_atom-1);
        k_end=nbor_k+fast_mul(numk/t_per_atom,n_stride)+(numk & (t_per_atom-1));
        nbor_k+=offset_k;
      } else {
        nbor_k+=nbor_pitch;
        nbor_k=dev_nbor[nbor_k];
        k_end=nbor_k+numk;
        nbor_k+=offset_k;
      }
      int nbork_start = nbor_k;

      // look up for zeta_ji: find i in the j's neighbor list
      int ijnum = 0;
      for ( ; nbor_k<k_end; nbor_k+=n_stride) { // tpa = 1
        int k=dev_packed[nbor_k];
        k &= NEIGHMASK;
        if (k == i) {
          ijnum = nbor_k;
          break;
        }
      }

      int iix = (ijnum - offset_j - 2*nbor_pitch) / n_stride; 
      int idx = iix*n_stride + j*t_per_atom + offset_j;
      numtyp zeta_ji = (numtyp)0;
      fetch(zeta_ji,idx,zeta_tex); // zeta_ji = zetaij[idx];

      numtyp fpfeng[4];
      int jiparam=elem2param[jtype*nelements*nelements+itype*nelements+itype];
      {
      numtyp4 ts1_jiparam = ts1[jiparam]; //fetch4(ts1_jiparam,jiparam,ts1_tex);
      numtyp jiparam_lam2 = ts1_jiparam.y;         
      numtyp4 ts2_jiparam = ts2[jiparam]; //fetch4(ts2_jiparam,jiparam,ts2_tex);
      numtyp jiparam_bigb = ts2_jiparam.y;
      numtyp jiparam_bigr = ts2_jiparam.z;
      numtyp jiparam_bigd = ts2_jiparam.w;
      numtyp4 ts3_jiparam = ts3[jiparam]; //fetch4(ts3_jiparam,jiparam,ts3_tex);
      numtyp jiparam_c1 = ts3_jiparam.x;
      numtyp jiparam_c2 = ts3_jiparam.y;
      numtyp jiparam_c3 = ts3_jiparam.z;
      numtyp jiparam_c4 = ts3_jiparam.w;
      numtyp4 ts5_jiparam = ts5[jiparam]; //fetch4(ts5_jiparam,jiparam,ts5_tex);
      numtyp jiparam_beta = ts5_jiparam.x;
      numtyp jiparam_powern = ts5_jiparam.y;
      force_zeta(jiparam_bigb, jiparam_bigr, jiparam_bigd, jiparam_lam2,
                 jiparam_beta, jiparam_powern, jiparam_c1, jiparam_c2, jiparam_c3,
                 jiparam_c4, rsq1, zeta_ji, eflag, fpfeng);
      }
      numtyp force = fpfeng[0];
      f.x += delr1[0]*force;
      f.y += delr1[1]*force;
      f.z += delr1[2]*force;
      numtyp prefactor = fpfeng[1];

      if (eflag>0) {
        energy+=fpfeng[2];
      }
      if (vflag>0) {
        numtyp mforce = -force;
        virial[0] += mdelr1[0]*mdelr1[0]*mforce;
        virial[1] += mdelr1[1]*mdelr1[1]*mforce;
        virial[2] += mdelr1[2]*mdelr1[2]*mforce;
        virial[3] += mdelr1[0]*mdelr1[1]*mforce;
        virial[4] += mdelr1[0]*mdelr1[2]*mforce;
        virial[5] += mdelr1[1]*mdelr1[2]*mforce;
      }

      // attractive forces

      for (nbor_k = nbork_start ; nbor_k<k_end; nbor_k+=n_stride) {
        int k=dev_packed[nbor_k];
        k &= NEIGHMASK;

        if (k == i) continue;

        numtyp4 kx; fetch4(kx,k,pos_tex);
        int ktype=kx.w;
        ktype=map[ktype];
        int jikparam=elem2param[jtype*nelements*nelements+itype*nelements+ktype];

        numtyp delr2[3];
        delr2[0] = kx.x-jx.x;
        delr2[1] = kx.y-jx.y;
        delr2[2] = kx.z-jx.z;
        numtyp rsq2 = delr2[0]*delr2[0] + delr2[1]*delr2[1] + delr2[2]*delr2[2];

        if (rsq2 > cutsq[jikparam]) continue;
        numtyp r2 = ucl_sqrt(rsq2);
        numtyp r2inv = ucl_recip(r2);

        numtyp fj[3], fk[3];
        {
        numtyp4 ts1_jikparam = ts1[jikparam]; //fetch4(ts1_jikparam,jikparam,ts1_tex);
        numtyp jikparam_lam3 = ts1_jikparam.z;
        numtyp jikparam_powermint = ts1_jikparam.w;
        numtyp4 ts2_jikparam = ts2[jikparam]; //fetch4(ts2_jikparam,jikparam,ts2_tex);
        numtyp jikparam_bigr = ts2_jikparam.z;
        numtyp jikparam_bigd = ts2_jikparam.w;
        numtyp4 ts4_jikparam = ts4[jikparam]; //fetch4(ts4_jikparam,jikparam,ts4_tex);
        numtyp jikparam_c = ts4_jikparam.x;
        numtyp jikparam_d = ts4_jikparam.y;
        numtyp jikparam_h = ts4_jikparam.z;
        numtyp jikparam_gamma = ts4_jikparam.w;
        attractive_fj(jikparam_bigr, jikparam_bigd, jikparam_powermint, 
                      jikparam_lam3, jikparam_c, jikparam_d, jikparam_h, 
                      jikparam_gamma, prefactor, r1, r1inv, r2, r2inv, mdelr1, delr2, 
                      fj);
        }
        f.x += fj[0];
        f.y += fj[1];
        f.z += fj[2];

        int kk = (nbor_k - offset_k - 2*nbor_pitch) / n_stride; // tpa = 1
        int idx = kk*n_stride + j*t_per_atom + offset_k;
        numtyp zeta_jk = (numtyp)0;
        fetch(zeta_jk,idx,zeta_tex); // zetaij[idx];

        numtyp prefactor_jk;
        int jkparam=elem2param[jtype*nelements*nelements+ktype*nelements+ktype];
        {
        numtyp4 ts1_jkparam = ts1[jkparam]; //fetch4(ts1_jkparam,jkparam,ts1_tex);
        numtyp jkparam_lam2 = ts1_jkparam.y;         
        numtyp4 ts2_jkparam = ts2[jkparam]; //fetch4(ts2_jkparam,jkparam,ts2_tex);
        numtyp jkparam_bigb = ts2_jkparam.y;
        numtyp jkparam_bigr = ts2_jkparam.z;
        numtyp jkparam_bigd = ts2_jkparam.w;
        numtyp4 ts3_jkparam = ts3[jkparam]; //fetch4(ts3_jkparam,jkparam,ts3_tex);
        numtyp jkparam_c1 = ts3_jkparam.x;
        numtyp jkparam_c2 = ts3_jkparam.y;
        numtyp jkparam_c3 = ts3_jkparam.z;
        numtyp jkparam_c4 = ts3_jkparam.w;
        numtyp4 ts5_jkparam = ts5[jkparam]; //fetch4(ts5_jkparam,jkparam,ts5_tex);
        numtyp jkparam_beta = ts5_jkparam.x;
        numtyp jkparam_powern = ts5_jkparam.y;
        prefactor_jk = (numtyp)-0.5 * 
          ters_fa(r2, jkparam_bigb, jkparam_bigr, jkparam_bigd, jkparam_lam2) *
          ters_bij_d(zeta_jk, jkparam_beta, jkparam_powern, 
                     jkparam_c1, jkparam_c2, jkparam_c3, jkparam_c4);
        }

        int jkiparam=elem2param[jtype*nelements*nelements+ktype*nelements+itype];
        {
        numtyp4 ts1_jkiparam = ts1[jkiparam]; //fetch4(ts1_jkiparam,jkiparam,ts1_tex);
        numtyp jkiparam_lam3 = ts1_jkiparam.z;
        numtyp jkiparam_powermint = ts1_jkiparam.w;
        numtyp4 ts2_jkiparam = ts2[jkiparam]; //fetch4(ts2_jkiparam,jkiparam,ts2_tex);
        numtyp jkiparam_bigr = ts2_jkiparam.z;
        numtyp jkiparam_bigd = ts2_jkiparam.w;
        numtyp4 ts4_jkiparam = ts4[jkiparam]; //fetch4(ts4_jkiparam,jkiparam,ts4_tex);
        numtyp jkiparam_c = ts4_jkiparam.x;
        numtyp jkiparam_d = ts4_jkiparam.y;
        numtyp jkiparam_h = ts4_jkiparam.z;
        numtyp jkiparam_gamma = ts4_jkiparam.w;
        attractive_fk(jkiparam_bigr, jkiparam_bigd, jkiparam_powermint, 
                      jkiparam_lam3,jkiparam_c, jkiparam_d, jkiparam_h, 
                      jkiparam_gamma, prefactor_jk, r2, r2inv, r1, r1inv, 
                      delr2, mdelr1, fk);
        }
        f.x += fk[0];
        f.y += fk[1];
        f.z += fk[2];
      }
    } // for nbor

    #ifdef THREE_CONCURRENT
    store_answers(f,energy,virial,ii,inum,tid,tpa_sq,offset,
                  eflag,vflag,ans,engv);
    #else
    store_answers_p(f,energy,virial,ii,inum,tid,tpa_sq,offset,
                    eflag,vflag,ans,engv);
    #endif

  } // if ii
}

__kernel void k_tersoff_three_end_vatom(const __global numtyp4 *restrict x_, 
                                        const __global numtyp4 *restrict ts1_in,
                                        const __global numtyp4 *restrict ts2_in,
      	                                const __global numtyp4 *restrict ts3_in,
      	                                const __global numtyp4 *restrict ts4_in,
                                        const __global numtyp4 *restrict ts5_in,
                                        const __global numtyp *restrict cutsq,
                                        const __global int *restrict map,
                                        const __global int *restrict elem2param,
                                        const int nelements, const int nparams,
                                        const __global numtyp *restrict zetaij,
                                        const __global int * dev_nbor, 
                                        const __global int * dev_packed, 
                                        __global acctyp4 *restrict ans, 
                                        __global acctyp *restrict engv, 
                                        const int eflag, const int vflag, 
                                        const int inum,  const int nbor_pitch, 
                                        const int t_per_atom) {
  __local int tpa_sq, n_stride;
  tpa_sq=fast_mul(t_per_atom,t_per_atom);

  int tid, ii, offset;
  atom_info(tpa_sq,ii,tid,offset);
  
  __local numtyp4 ts1[SHARED_SIZE];
  __local numtyp4 ts2[SHARED_SIZE];
  __local numtyp4 ts3[SHARED_SIZE];
  __local numtyp4 ts4[SHARED_SIZE];
  __local numtyp4 ts5[SHARED_SIZE];
  if (tid<nparams) {
    ts1[tid]=ts1_in[tid];
    ts2[tid]=ts2_in[tid];
    ts3[tid]=ts3_in[tid];
    ts4[tid]=ts4_in[tid];
    ts5[tid]=ts5_in[tid];
  }

  acctyp energy=(acctyp)0;
  acctyp4 f;
  f.x=(acctyp)0; f.y=(acctyp)0; f.z=(acctyp)0;
  acctyp virial[6];
  for (int i=0; i<6; i++)
    virial[i]=(acctyp)0;

  __syncthreads();
  
  if (ii<inum) {
    int i, numj, nbor_j, nbor_end, k_end;

    int offset_j=offset/t_per_atom;
    nbor_info(dev_nbor,dev_packed,nbor_pitch,t_per_atom,ii,offset_j,i,numj,
              n_stride,nbor_end,nbor_j);
    int offset_k=tid & (t_per_atom-1);

    numtyp4 ix; fetch4(ix,i,pos_tex); //x_[i];
    int itype=ix.w; 
    itype=map[itype];

    for ( ; nbor_j<nbor_end; nbor_j+=n_stride) {
  
      int j=dev_packed[nbor_j];
      j &= NEIGHMASK;

      numtyp4 jx; fetch4(jx,j,pos_tex); //x_[j];
      int jtype=jx.w;
      jtype=map[jtype];

      // Compute r12
      numtyp delr1[3];
      delr1[0] = jx.x-ix.x;
      delr1[1] = jx.y-ix.y;
      delr1[2] = jx.z-ix.z;
      numtyp rsq1 = delr1[0]*delr1[0] + delr1[1]*delr1[1] + delr1[2]*delr1[2];

      int ijparam=elem2param[itype*nelements*nelements+jtype*nelements+jtype];

      if (rsq1 > cutsq[ijparam]) continue;
      numtyp r1 = ucl_sqrt(rsq1);
      numtyp r1inv = ucl_recip(r1);

      numtyp mdelr1[3];
      mdelr1[0] = -delr1[0];
      mdelr1[1] = -delr1[1];
      mdelr1[2] = -delr1[2];

      int nbor_k=j+nbor_pitch;
      int numk=dev_nbor[nbor_k]; 
      if (dev_nbor==dev_packed) {
        nbor_k+=nbor_pitch+fast_mul(j,t_per_atom-1);
        k_end=nbor_k+fast_mul(numk/t_per_atom,n_stride)+(numk & (t_per_atom-1));
        nbor_k+=offset_k;
      } else {
        nbor_k+=nbor_pitch;
        nbor_k=dev_nbor[nbor_k];
        k_end=nbor_k+numk;
        nbor_k+=offset_k;
      }
      int nbork_start = nbor_k;

      // look up for zeta_ji
      int ijnum = 0;
      for ( ; nbor_k<k_end; nbor_k+=n_stride) {
        int k=dev_packed[nbor_k];
        k &= NEIGHMASK;
        if (k == i) {
          ijnum = nbor_k;
          break;
        }
      }

      int iix = (ijnum - offset_j - 2*nbor_pitch) / n_stride;
      int idx = iix*n_stride + j*t_per_atom + offset_j;
      numtyp zeta_ji = (numtyp)0;
      fetch(zeta_ji,idx,zeta_tex); // zetaij[idx];

      numtyp fpfeng[4];
      int jiparam=elem2param[jtype*nelements*nelements+itype*nelements+itype];
      {
      numtyp4 ts1_jiparam = ts1[jiparam]; //fetch4(ts1_jiparam,jiparam,ts1_tex);
      numtyp jiparam_lam2 = ts1_jiparam.y;         
      numtyp4 ts2_jiparam = ts2[jiparam]; //fetch4(ts2_jiparam,jiparam,ts2_tex);
      numtyp jiparam_bigb = ts2_jiparam.y;
      numtyp jiparam_bigr = ts2_jiparam.z;
      numtyp jiparam_bigd = ts2_jiparam.w;
      numtyp4 ts3_jiparam = ts3[jiparam]; //fetch4(ts3_jiparam,jiparam,ts3_tex);
      numtyp jiparam_c1 = ts3_jiparam.x;
      numtyp jiparam_c2 = ts3_jiparam.y;
      numtyp jiparam_c3 = ts3_jiparam.z;
      numtyp jiparam_c4 = ts3_jiparam.w;
      numtyp4 ts5_jiparam = ts5[jiparam]; //fetch4(ts5_jiparam,jiparam,ts5_tex);
      numtyp jiparam_beta = ts5_jiparam.x;
      numtyp jiparam_powern = ts5_jiparam.y;
      force_zeta(jiparam_bigb, jiparam_bigr, jiparam_bigd, jiparam_lam2,
                 jiparam_beta, jiparam_powern, jiparam_c1, jiparam_c2, jiparam_c3,
                 jiparam_c4, rsq1, zeta_ji, eflag, fpfeng);
      }
      numtyp force = fpfeng[0];
      f.x += delr1[0]*force;
      f.y += delr1[1]*force;
      f.z += delr1[2]*force;
      numtyp prefactor = fpfeng[1];

      if (eflag>0) {
        energy+=fpfeng[2];
      }
      if (vflag>0) {
        numtyp mforce = -force;
        virial[0] += mdelr1[0]*mdelr1[0]*mforce;
        virial[1] += mdelr1[1]*mdelr1[1]*mforce;
        virial[2] += mdelr1[2]*mdelr1[2]*mforce;
        virial[3] += mdelr1[0]*mdelr1[1]*mforce;
        virial[4] += mdelr1[0]*mdelr1[2]*mforce;
        virial[5] += mdelr1[1]*mdelr1[2]*mforce;
      }

      // attractive forces

      for (nbor_k = nbork_start; nbor_k<k_end; nbor_k+=n_stride) {
        int k=dev_packed[nbor_k];
        k &= NEIGHMASK;

        if (k == i) continue;

        numtyp4 kx; fetch4(kx,k,pos_tex);
        int ktype=kx.w;
        ktype=map[ktype];
        int jikparam=elem2param[jtype*nelements*nelements+itype*nelements+ktype];

        numtyp delr2[3];
        delr2[0] = kx.x-jx.x;
      	delr2[1] = kx.y-jx.y;
        delr2[2] = kx.z-jx.z;
        numtyp rsq2 = delr2[0]*delr2[0] + delr2[1]*delr2[1] + delr2[2]*delr2[2];

        if (rsq2 > cutsq[jikparam]) continue;
        numtyp r2 = ucl_sqrt(rsq2);
        numtyp r2inv = ucl_recip(r2);

        numtyp fi[3], fj[3], fk[3];
        {
        numtyp4 ts1_jikparam = ts1[jikparam]; //fetch4(ts1_jikparam,jikparam,ts1_tex);
        numtyp jikparam_lam3 = ts1_jikparam.z;
        numtyp jikparam_powermint = ts1_jikparam.w;
        numtyp4 ts2_jikparam = ts2[jikparam]; //fetch4(ts2_jikparam,jikparam,ts2_tex);
        numtyp jikparam_bigr = ts2_jikparam.z;
        numtyp jikparam_bigd = ts2_jikparam.w;
        numtyp4 ts4_jikparam = ts4[jikparam]; //fetch4(ts4_jikparam,jikparam,ts4_tex);
        numtyp jikparam_c = ts4_jikparam.x;
        numtyp jikparam_d = ts4_jikparam.y;
        numtyp jikparam_h = ts4_jikparam.z;
        numtyp jikparam_gamma = ts4_jikparam.w;
        attractive(jikparam_bigr, jikparam_bigd, jikparam_powermint,
                   jikparam_lam3, jikparam_c, jikparam_d, jikparam_h, 
                   jikparam_gamma, prefactor, r1, r1inv, r2, r2inv, mdelr1, delr2,
                   fi, fj, fk);
        }
        f.x += fj[0];
        f.y += fj[1];
        f.z += fj[2];

        virial[0] += THIRD*(mdelr1[0]*fj[0] + delr2[0]*fk[0]);
        virial[1] += THIRD*(mdelr1[1]*fj[1] + delr2[1]*fk[1]);
        virial[2] += THIRD*(mdelr1[2]*fj[2] + delr2[2]*fk[2]);
        virial[3] += THIRD*(mdelr1[0]*fj[1] + delr2[0]*fk[1]);
        virial[4] += THIRD*(mdelr1[0]*fj[2] + delr2[0]*fk[2]);
        virial[5] += THIRD*(mdelr1[1]*fj[2] + delr2[1]*fk[2]);

        int kk = (nbor_k - offset_k - 2*nbor_pitch) / n_stride;
        int idx = kk*n_stride + j*t_per_atom + offset_k;
        numtyp zeta_jk = (numtyp)0;
        fetch(zeta_jk,idx,zeta_tex); // zetaij[idx];

        numtyp prefactor_jk;
        int jkparam=elem2param[jtype*nelements*nelements+ktype*nelements+ktype];
        {
        numtyp4 ts1_jkparam = ts1[jkparam]; //fetch4(ts1_jkparam,jkparam,ts1_tex);
        numtyp jkparam_lam2 = ts1_jkparam.y;         
        numtyp4 ts2_jkparam = ts2[jkparam]; //fetch4(ts2_jkparam,jkparam,ts2_tex);
        numtyp jkparam_bigb = ts2_jkparam.y;
        numtyp jkparam_bigr = ts2_jkparam.z;
        numtyp jkparam_bigd = ts2_jkparam.w;
        numtyp4 ts3_jkparam = ts3[jkparam]; //fetch4(ts3_jkparam,jkparam,ts3_tex);
        numtyp jkparam_c1 = ts3_jkparam.x;
        numtyp jkparam_c2 = ts3_jkparam.y;
        numtyp jkparam_c3 = ts3_jkparam.z;
        numtyp jkparam_c4 = ts3_jkparam.w;
        numtyp4 ts5_jkparam = ts5[jkparam]; //fetch4(ts5_jkparam,jkparam,ts5_tex);
        numtyp jkparam_beta = ts5_jkparam.x;
        numtyp jkparam_powern = ts5_jkparam.y;
        prefactor_jk = (numtyp)-0.5 *
          ters_fa(r2, jkparam_bigb, jkparam_bigr, jkparam_bigd, jkparam_lam2) *
          ters_bij_d(zeta_jk, jkparam_beta, jkparam_powern, 
                     jkparam_c1, jkparam_c2, jkparam_c3, jkparam_c4);
        }

        int jkiparam=elem2param[jtype*nelements*nelements+ktype*nelements+itype];
        {
        numtyp4 ts1_jkiparam = ts1[jkiparam]; //fetch4(ts1_jkiparam,jkiparam,ts1_tex);
        numtyp jkiparam_lam3 = ts1_jkiparam.z;
        numtyp jkiparam_powermint = ts1_jkiparam.w;
        numtyp4 ts2_jkiparam = ts2[jkiparam]; //fetch4(ts2_jkiparam,jkiparam,ts2_tex);
        numtyp jkiparam_bigr = ts2_jkiparam.z;
        numtyp jkiparam_bigd = ts2_jkiparam.w;
        numtyp4 ts4_jkiparam = ts4[jkiparam]; //fetch4(ts4_jkiparam,jkiparam,ts4_tex);
        numtyp jkiparam_c = ts4_jkiparam.x;
        numtyp jkiparam_d = ts4_jkiparam.y;
        numtyp jkiparam_h = ts4_jkiparam.z;
        numtyp jkiparam_gamma = ts4_jkiparam.w;
        attractive(jkiparam_bigr, jkiparam_bigd, jkiparam_powermint,
                   jkiparam_lam3, jkiparam_c, jkiparam_d, jkiparam_h, 
                   jkiparam_gamma, prefactor_jk, r2, r2inv, r1, r1inv, delr2, mdelr1,
                   fi, fj, fk);
        }
        f.x += fk[0];
        f.y += fk[1];
        f.z += fk[2];

        virial[0] += THIRD*(delr2[0]*fj[0] + mdelr1[0]*fk[0]);
        virial[1] += THIRD*(delr2[1]*fj[1] + mdelr1[1]*fk[1]);
        virial[2] += THIRD*(delr2[2]*fj[2] + mdelr1[2]*fk[2]);
        virial[3] += THIRD*(delr2[0]*fj[1] + mdelr1[0]*fk[1]);
        virial[4] += THIRD*(delr2[0]*fj[2] + mdelr1[0]*fk[2]);
        virial[5] += THIRD*(delr2[1]*fj[2] + mdelr1[1]*fk[2]);
      }
    } // for nbor

    #ifdef THREE_CONCURRENT
    store_answers(f,energy,virial,ii,inum,tid,tpa_sq,offset,
                  eflag,vflag,ans,engv);
    #else
    store_answers_p(f,energy,virial,ii,inum,tid,tpa_sq,offset,
                    eflag,vflag,ans,engv);
    #endif
  } // if ii
}

PROGRAM incompact3d

  USE decomp_2d
  USE decomp_2d_poisson
  use decomp_2d_io
  USE variables
  USE ibm
  USE param
  USE var
  USE MPI
  USE derivX
  USE derivZ
  USE case
  USE simulation_stats

#ifdef FORCES
  USE forces
#endif
  implicit none

  integer :: code,nlock,i,j,k,ii,bcx,bcy,bcz,fh,ierror
  real(mytype) :: x,y,z,timeleft

  integer :: ErrFlag, nargin, FNLength, status, DecInd, output_counter
  logical :: back
  character(len=80) :: InputFN, FNBase
  character(len=20) :: filename

  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  !! Initialisation
  !!-------------------------------------------------------------------------------

  !! Initialise MPI
  call MPI_INIT(code)
  call MPI_COMM_RANK(MPI_COMM_WORLD,nrank,ierror)
  call MPI_COMM_SIZE(MPI_COMM_WORLD,nproc,ierror)

  ! Handle input file like a boss -- GD
  nargin=command_argument_count()
  if (nargin <1) then
     InputFN='input.i3d'
     if (nrank==0) print*, 'Incompact3d is run with the default file -->', InputFN
  elseif (nargin.ge.1) then
     if (nrank==0) print*, 'Program is run with the provided file -->', InputFN

     call get_command_argument(1,InputFN,FNLength,status)
     back=.true.
     FNBase=inputFN((index(InputFN,'/',back)+1):len(InputFN))
     DecInd=index(FNBase,'.',back)
     if (DecInd >1) then
        FNBase=FNBase(1:(DecInd-1))
     end if
  endif

  call parameter(InputFN)

  call decomp_2d_init(nx,ny,nz,p_row,p_col)
  call init_coarser_mesh_statS(nstat,nstat,nstat,.true.)    !start from 1 == true
  call init_coarser_mesh_statV(nvisu,nvisu,nvisu,.true.)    !start from 1 == true
  call init_coarser_mesh_statP(nprobe,nprobe,nprobe,.true.) !start from 1 == true
  !div: nx ny nz --> nxm ny nz --> nxm nym nz --> nxm nym nzm
  call decomp_info_init(nxm, nym, nzm, ph1)
  call decomp_info_init(nxm, ny, nz, ph4)
  !gradp: nxm nym nzm -> nxm nym nz --> nxm ny nz --> nx ny nz
  call decomp_info_init(nxm, ny, nz, ph2)
  call decomp_info_init(nxm, nym, nz, ph3)

  call init_variables()

  call schemes()

#ifdef ELES
  call filter()
#endif

  !if (nrank==0) call stabiltemp()

  call decomp_2d_poisson_init()
  call decomp_info_init(nxm,nym,nzm,phG)

#ifdef ELES
  call init_explicit_les()
#endif

  if (irestart==0) then
     call init(ux1,uy1,uz1,ep1,phi1,dux1,duy1,duz1,phis1,phiss1)
  else
     call restart(ux1,uy1,uz1,dux1,duy1,duz1,ep1,pp3,phi1,px1,py1,pz1,0)
  endif

  if (iibm.eq.2) then
     call genepsi3d(ep1)
  else if (iibm.eq.1) then
     call body(ux1,uy1,uz1,ep1,0)
  endif

#ifdef FORCES
  call init_forces()
  if (irestart==1) call restart_forces(0)
#endif

  call test_speed_min_max(ux1,uy1,uz1)
  if (iscalar==1) call test_scalar_min_max(phi1)

  call simu_stats(1)

  !!-------------------------------------------------------------------------------
  !! End initialisation
  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  do itime=ifirst,ilast
     t=itime*dt
     call simu_stats(2)
     do itr=1,iadvance_time

        !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        !! Initialise timestep
        !!-------------------------------------------------------------------------
        call boundary_conditions(ux1,uy1,uz1,phi1)
        !!-------------------------------------------------------------------------
        !! End initialise timestep
        !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

        CALL calculate_transeq_rhs(dux1,duy1,duz1,ux1,uy1,uz1,ep1,phi1)

        !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        !! Time integrate transport equations
        !!-------------------------------------------------------------------------
        call int_time_momentum(ux1,uy1,uz1,dux1,duy1,duz1)
        call pre_correc(ux1,uy1,uz1,ep1)
        !!-------------------------------------------------------------------------
        !! End time integrate transport equations
        !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

        if (iibm==1) then !solid body old school
           call corgp_IBM(ux1,uy1,uz1,px1,py1,pz1,1)
           call body(ux1,uy1,uz1,ep1,1)
           call corgp_IBM(ux1,uy1,uz1,px1,py1,pz1,2)
        endif

        !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        !! Poisson solver and velocity correction
        !!-------------------------------------------------------------------------
        call solve_poisson(pp3, ux1, uy1, uz1, ep1)
        call gradp(px1,py1,pz1,pp3)
        call corpg(ux1,uy1,uz1,px1,py1,pz1)
        !!-------------------------------------------------------------------------
        !! End Poisson solver and velocity correction
        !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

        if (mod(itime,10)==0) then
           call divergence(ux1,uy1,uz1,ep1,dv3,2)
           call test_speed_min_max(ux1,uy1,uz1)
           if (iscalar==1) call test_scalar_min_max(phi1)
        endif

     enddo !! End sub timesteps
#ifdef FORCES
     call force(ux1,uy1,ep1,ta1,tb1,tc1,td1,di1,&
          ux2,uy2,ta2,tb2,tc2,td2,di2)
     if (mod(itime,icheckpoint).eq.0) then
        call restart_forces(1)
     endif
#endif

     !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
     !! Post-processing / IO
     !!----------------------------------------------------------------------------
     call postprocessing(ux1,uy1,uz1,phi1,ep1)

     if (mod(itime,icheckpoint).eq.0) then
        call restart(ux1,uy1,uz1,dux1,duy1,duz1,ep1,pp3,phi1,px1,py1,pz1,1)
     endif

     call simu_stats(3)
     !!----------------------------------------------------------------------------
     !! End post-processing / IO
     !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  enddo !! End time loop

  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  !! End simulation
  !!-------------------------------------------------------------------------------
  call simu_stats(4)
  call decomp_2d_finalize
  CALL MPI_FINALIZE(code)

END PROGRAM incompact3d

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!  SUBROUTINE: calculate_transeq_rhs
!!      AUTHOR: Paul Bartholomew
!! DESCRIPTION: Calculates the right hand sides of all transport
!!              equations - momentum, scalar transport, etc.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
SUBROUTINE calculate_transeq_rhs(dux1,duy1,duz1,ux1,uy1,uz1,ep1,phi1)

  USE decomp_2d, ONLY : mytype, xsize
  USE variables, ONLY : numscalar
  USE param, ONLY : ntime
  USE transeq, ONLY : momentum_rhs_eq
  
  IMPLICIT NONE

  !! Inputs
  REAL(mytype), DIMENSION(xsize(1), xsize(2), xsize(3)), INTENT(IN) :: ux1, uy1, uz1
  REAL(mytype), DIMENSION(xsize(1), xsize(2), xsize(3), numscalar), INTENT(IN) :: phi1
  REAL(mytype), DIMENSION(xsize(1), xsize(2), xsize(3)), INTENT(IN) :: ep1

  !! Outputs
  REAL(mytype), DIMENSION(xsize(1), xsize(2), xsize(3), ntime) :: dux1, duy1, duz1
  
  !! Momentum equations
  CALL momentum_rhs_eq(dux1,duy1,duz1,ux1,uy1,uz1,ep1,phi1)

  !! Scalar equations

  !! Other (LMN, ...)
  
END SUBROUTINE calculate_transeq_rhs

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!  SUBROUTINE: solve_poisson
!!      AUTHOR: Paul Bartholomew
!! DESCRIPTION: Takes the intermediate momentum field as input,
!!              computes div and solves pressure-Poisson equation.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
SUBROUTINE solve_poisson(pp3, ux1, uy1, uz1, ep1)

  USE decomp_2d, ONLY : mytype, xsize, ph1
  USE decomp_2d_poisson, ONLY : poisson
  USE var, ONLY : nzmsize

  IMPLICIT NONE

  INTEGER :: nlock

  !! Inputs
  REAL(mytype), DIMENSION(xsize(1), xsize(2), xsize(3)), INTENT(IN) :: ux1, uy1, uz1
  REAL(mytype), DIMENSION(xsize(1), xsize(2), xsize(3)), INTENT(IN) :: ep1

  !! Outputs
  REAL(mytype), DIMENSION(ph1%zst(1):ph1%zen(1), ph1%zst(2):ph1%zen(2), nzmsize) :: pp3

  nlock = 1 !! Corresponds to computing div(u*)
  CALL divergence(ux1,uy1,uz1,ep1,pp3,nlock)

  CALL poisson(pp3)

END SUBROUTINE solve_poisson

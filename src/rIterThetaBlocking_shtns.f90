#include "perflib_preproc.cpp"
module rIterThetaBlocking_shtns_mod
#ifdef WITHOMP
   use omp_lib
#endif
   use precision_mod
   use rIterThetaBlocking_mod, only: rIterThetaBlocking_t
   use num_param, only: phy2lm_counter, lm2phy_counter, nl_counter, &
       &                td_counter
   use parallel_mod, only: get_openmp_blocks
   use truncation, only: lm_max, lmP_max, l_max, lmP_max_dtB,      &
       &                 n_phi_maxStr, n_theta_maxStr, n_r_maxStr, &
       &                 n_theta_max, n_phi_max, nrp, n_r_max
   use logic, only: l_mag, l_conv, l_mag_kin, l_heat, l_ht, l_anel,  &
       &            l_mag_LF, l_conv_nl, l_mag_nl, l_b_nl_cmb,       &
       &            l_b_nl_icb, l_rot_ic, l_cond_ic, l_rot_ma,       &
       &            l_cond_ma, l_dtB, l_store_frame, l_movie_oc,     &
       &            l_TO, l_chemical_conv, l_probe,                  &
       &            l_precession, l_centrifuge, l_adv_curl
   use radial_data, only: n_r_cmb, n_r_icb
   use radial_functions, only: or2, orho1
   use constants, only: zero
   use leg_helper_mod, only: leg_helper_t
   use nonlinear_lm_mod, only:nonlinear_lm_t
   use grid_space_arrays_mod, only: grid_space_arrays_t
   use TO_arrays_mod, only: TO_arrays_t
   use dtB_arrays_mod, only: dtB_arrays_t
   use torsional_oscillations, only: getTO, getTOnext, getTOfinish
#ifdef WITH_MPI
   use graphOut_mod, only: graphOut_mpi
#else
   use graphOut_mod, only: graphOut
#endif
   use dtB_mod, only: get_dtBLM, get_dH_dtBLM
   use out_movie, only: store_movie_frame
   use outRot, only: get_lorentz_torque
   use courant_mod, only: courant
   use nonlinear_bcs, only: get_br_v_bcs, v_rigid_boundary
   use nl_special_calc
   use shtns
   use horizontal_data
   use fields, only: s_Rloc,ds_Rloc, z_Rloc,dz_Rloc, p_Rloc,dp_Rloc, &
       &             b_Rloc,db_Rloc,ddb_Rloc, aj_Rloc,dj_Rloc,       &
       &             w_Rloc,dw_Rloc,ddw_Rloc, xi_Rloc
   use physical_parameters, only: ktops, kbots, n_r_LCR
   use probe_mod

   implicit none

   private

   type, public, extends(rIterThetaBlocking_t) :: rIterThetaBlocking_shtns_t
      integer :: nThreads
      type(grid_space_arrays_t) :: gsa
      type(TO_arrays_t) :: TO_arrays
      type(dtB_arrays_t) :: dtB_arrays
      type(nonlinear_lm_t) :: nl_lm
      real(cp) :: lorentz_torque_ic,lorentz_torque_ma
   contains
      procedure :: initialize => initialize_rIterThetaBlocking_shtns
      procedure :: finalize => finalize_rIterThetaBlocking_shtns
      procedure :: do_iteration => do_iteration_ThetaBlocking_shtns
      procedure :: getType => getThisType
      procedure :: transform_to_grid_space_shtns => transform_to_grid_space_shtns
      procedure :: transform_to_lm_space_shtns => transform_to_lm_space_shtns
   end type rIterThetaBlocking_shtns_t

contains

   function getThisType(this)

      class(rIterThetaBlocking_shtns_t) :: this
      character(len=100) :: getThisType
      getThisType="rIterThetaBlocking_shtns_t"

   end function getThisType
!------------------------------------------------------------------------------
   subroutine initialize_rIterThetaBlocking_shtns(this)

      class(rIterThetaBlocking_shtns_t) :: this

      call this%allocate_common_arrays()
      call this%gsa%initialize()
      if ( l_TO ) call this%TO_arrays%initialize()
      call this%dtB_arrays%initialize()
      call this%nl_lm%initialize(lmP_max)

   end subroutine initialize_rIterThetaBlocking_shtns
!------------------------------------------------------------------------------
   subroutine finalize_rIterThetaBlocking_shtns(this)

      class(rIterThetaBlocking_shtns_t) :: this

      call this%deallocate_common_arrays()
      call this%gsa%finalize()
      if ( l_TO ) call this%TO_arrays%finalize()
      call this%dtB_arrays%finalize()
      call this%nl_lm%finalize()

   end subroutine finalize_rIterThetaBlocking_shtns
!------------------------------------------------------------------------------
   subroutine do_iteration_ThetaBlocking_shtns(this,nR,nBc,time,dt,dtLast, &
              &           dsdt,dwdt,dzdt,dpdt,dxidt,dbdt,djdt,             &
              &           dVxVhLM,dVxBhLM,dVSrLM,dVXirLM,                  &
              &           br_vt_lm_cmb,br_vp_lm_cmb,                       &
              &           br_vt_lm_icb,br_vp_lm_icb,                       &
              &           lorentz_torque_ic, lorentz_torque_ma,            &
              &           HelLMr,Hel2LMr,HelnaLMr,Helna2LMr,viscLMr,       &
              &           uhLMr,duhLMr,gradsLMr,fconvLMr,fkinLMr,fviscLMr, &
              &           fpoynLMr,fresLMr,EperpLMr,EparLMr,EperpaxiLMr,   &
              &           EparaxiLMr)

      class(rIterThetaBlocking_shtns_t) :: this
      integer,  intent(in) :: nR,nBc
      real(cp), intent(in) :: time,dt,dtLast

      complex(cp), intent(out) :: dwdt(:),dzdt(:),dpdt(:),dsdt(:),dVSrLM(:)
      complex(cp), intent(out) :: dxidt(:),dVXirLM(:)
      complex(cp), intent(out) :: dbdt(:),djdt(:),dVxVhLM(:),dVxBhLM(:)
      !---- Output of nonlinear products for nonlinear
      !     magnetic boundary conditions (needed in s_updateB.f):
      complex(cp), intent(out) :: br_vt_lm_cmb(:) ! product br*vt at CMB
      complex(cp), intent(out) :: br_vp_lm_cmb(:) ! product br*vp at CMB
      complex(cp), intent(out) :: br_vt_lm_icb(:) ! product br*vt at ICB
      complex(cp), intent(out) :: br_vp_lm_icb(:) ! product br*vp at ICB
      real(cp),    intent(out) :: lorentz_torque_ma, lorentz_torque_ic
      real(cp),    intent(out) :: HelLMr(:),Hel2LMr(:),HelnaLMr(:),Helna2LMr(:)
      real(cp),    intent(out) :: viscLMr(:)
      real(cp),    intent(out) :: uhLMr(:), duhLMr(:) ,gradsLMr(:)
      real(cp),    intent(out) :: fconvLMr(:), fkinLMr(:), fviscLMr(:)
      real(cp),    intent(out) :: fpoynLMr(:), fresLMr(:)
      real(cp),    intent(out) :: EperpLMr(:), EparLMr(:), EperpaxiLMr(:), EparaxiLMr(:)

      integer :: lm
      logical :: lGraphHeader=.false.
      logical :: DEBUG_OUTPUT=.false.
      real(cp) :: lorentz_torques_ic

      this%nR=nR
      this%nBc=nBc
      this%isRadialBoundaryPoint=(nR == n_r_cmb).or.(nR == n_r_icb)

      if ( this%l_cour ) then
         this%dtrkc=1.e10_cp
         this%dthkc=1.e10_cp
      end if
      if ( this%lTOCalc ) then
         !------ Zero lm coeffs for first theta block:
         call this%TO_arrays%set_zero()
      end if

      call this%leg_helper%legPrepG(this%nR,this%nBc,this%lDeriv,this%lRmsCalc, &
           &                        this%l_frame,this%lTOnext,this%lTOnext2,    &
           &                        this%lTOcalc)

      if (DEBUG_OUTPUT) then
         write(*,"(I3,A,I1,2(A,L1))") this%nR,": nBc = ", &
              & this%nBc,", lDeriv = ",this%lDeriv,", l_mag = ",l_mag
      end if


      this%lorentz_torque_ma = 0.0_cp
      this%lorentz_torque_ic = 0.0_cp
      lorentz_torques_ic = 0.0_cp

      call this%nl_lm%set_zero()

      call lm2phy_counter%start_count()
      call this%transform_to_grid_space_shtns(this%gsa, time)
      call lm2phy_counter%stop_count(l_increment=.false.)

      !--------- Calculation of nonlinear products in grid space:
      if ( (.not.this%isRadialBoundaryPoint) .or. this%lMagNlBc .or. &
      &     this%lRmsCalc ) then

         call nl_counter%start_count()
         PERFON('get_nl')
         call this%gsa%get_nl_shtns(time, dt, this%nR, this%nBc, this%lRmsCalc)
         PERFOFF
         call nl_counter%stop_count(l_increment=.false.)

         call phy2lm_counter%start_count()
         call this%transform_to_lm_space_shtns(this%gsa, this%nl_lm)
         call phy2lm_counter%stop_count(l_increment=.false.)

      else if ( l_mag ) then
         do lm=1,lmP_max
            this%nl_lm%VxBtLM(lm)=0.0_cp
            this%nl_lm%VxBpLM(lm)=0.0_cp
         end do
      end if

      !---- Calculation of nonlinear products needed for conducting mantle or
      !     conducting inner core if free stress BCs are applied:
      !     input are brc,vtc,vpc in (theta,phi) space (plus omegaMA and ..)
      !     ouput are the products br_vt_lm_icb, br_vt_lm_cmb, br_vp_lm_icb,
      !     and br_vp_lm_cmb in lm-space, respectively the contribution
      !     to these products from the points theta(nThetaStart)-theta(nThetaStop)
      !     These products are used in get_b_nl_bcs.
      if ( this%nR == n_r_cmb .and. l_b_nl_cmb ) then
         br_vt_lm_cmb(:)=zero
         br_vp_lm_cmb(:)=zero
         call get_br_v_bcs(this%gsa%brc,this%gsa%vtc,               &
              &            this%gsa%vpc,this%leg_helper%omegaMA,    &
              &            or2(this%nR),orho1(this%nR), 1,          &
              &            this%sizeThetaB,br_vt_lm_cmb,br_vp_lm_cmb)
      else if ( this%nR == n_r_icb .and. l_b_nl_icb ) then
         br_vt_lm_icb(:)=zero
         br_vp_lm_icb(:)=zero
         call get_br_v_bcs(this%gsa%brc,this%gsa%vtc,               &
              &            this%gsa%vpc,this%leg_helper%omegaIC,    &
              &            or2(this%nR),orho1(this%nR), 1,          &
              &            this%sizeThetaB,br_vt_lm_icb,br_vp_lm_icb)
      end if
      !--------- Calculate Lorentz torque on inner core:
      !          each call adds the contribution of the theta-block to
      !          lorentz_torque_ic
      if ( this%nR == n_r_icb .and. l_mag_LF .and. l_rot_ic .and. l_cond_ic  ) then
         lorentz_torques_ic=0.0_cp
         call get_lorentz_torque(lorentz_torques_ic,1,this%sizeThetaB,  &
              &                  this%gsa%brc,this%gsa%bpc,this%nR)
      end if

      !--------- Calculate Lorentz torque on mantle:
      !          note: this calculates a torque of a wrong sign.
      !          sign is reversed at the end of the theta blocking.
      if ( this%nR == n_r_cmb .and. l_mag_LF .and. l_rot_ma .and. l_cond_ma ) then
         call get_lorentz_torque(this%lorentz_torque_ma,1,this%sizeThetaB, &
              &                  this%gsa%brc,this%gsa%bpc,this%nR)
      end if

      !--------- Calculate courant condition parameters:
      if ( this%l_cour ) then
         call courant(this%nR,this%dtrkc,this%dthkc,this%gsa%vrc,          &
              &       this%gsa%vtc,this%gsa%vpc,this%gsa%brc,this%gsa%btc, &
              &       this%gsa%bpc,1 ,this%sizeThetaB)
      end if

      !--------- Since the fields are given at gridpoints here, this is a good
      !          point for graphical output:
      if ( this%l_graph ) then
#ifdef WITH_MPI
            call graphOut_mpi(time,this%nR,this%gsa%vrc,this%gsa%vtc,           &
                 &            this%gsa%vpc,this%gsa%brc,this%gsa%btc,           &
                 &            this%gsa%bpc,this%gsa%sc,this%gsa%pc,this%gsa%xic,&
                 &            1,this%sizeThetaB,lGraphHeader)
#else
            call graphOut(time,this%nR,this%gsa%vrc,this%gsa%vtc,           &
                 &        this%gsa%vpc,this%gsa%brc,this%gsa%btc,           &
                 &        this%gsa%bpc,this%gsa%sc,this%gsa%pc,this%gsa%xic,&
                 &        1 ,this%sizeThetaB,lGraphHeader)
#endif
      end if

      if ( this%l_probe_out ) then
         call probe_out(time,this%nR,this%gsa%vpc, 1,this%sizeThetaB)
      end if

      !--------- Helicity output:
      if ( this%lHelCalc ) then
         HelLMr(:)   =0.0_cp
         Hel2LMr(:)  =0.0_cp
         HelnaLMr(:) =0.0_cp
         Helna2LMr(:)=0.0_cp
         call get_helicity(this%gsa%vrc,this%gsa%vtc,this%gsa%vpc,         &
              &            this%gsa%cvrc,this%gsa%dvrdtc,this%gsa%dvrdpc,  &
              &            this%gsa%dvtdrc,this%gsa%dvpdrc,HelLMr,Hel2LMr, &
              &            HelnaLMr,Helna2LMr,this%nR,1 )
      end if

      !-- Viscous heating:
      if ( this%lPowerCalc ) then
         viscLMr(:)=0.0_cp
         call get_visc_heat(this%gsa%vrc,this%gsa%vtc,this%gsa%vpc,          &
              &             this%gsa%cvrc,this%gsa%dvrdrc,this%gsa%dvrdtc,   &
              &             this%gsa%dvrdpc,this%gsa%dvtdrc,this%gsa%dvtdpc, &
              &             this%gsa%dvpdrc,this%gsa%dvpdpc,viscLMr,         &
              &             this%nR,1)
      end if

      !-- horizontal velocity :
      if ( this%lViscBcCalc ) then
         gradsLMr(:)=0.0_cp
         uhLMr(:)   =0.0_cp
         duhLMr(:)  =0.0_cp
         call get_nlBLayers(this%gsa%vtc,this%gsa%vpc,this%gsa%dvtdrc,    &
              &             this%gsa%dvpdrc,this%gsa%drSc,this%gsa%dsdtc, &
              &             this%gsa%dsdpc,uhLMr,duhLMr,gradsLMr,nR,1 )
      end if

      !-- Radial flux profiles
      if ( this%lFluxProfCalc ) then
         fconvLMr(:)=0.0_cp
         fkinLMr(:) =0.0_cp
         fviscLMr(:)=0.0_cp
         fpoynLMr(:)=0.0_cp
         fresLMr(:) =0.0_cp
         call get_fluxes(this%gsa%vrc,this%gsa%vtc,this%gsa%vpc,            &
              &          this%gsa%dvrdrc,this%gsa%dvtdrc,this%gsa%dvpdrc,   &
              &          this%gsa%dvrdtc,this%gsa%dvrdpc,this%gsa%sc,       &
              &          this%gsa%pc,this%gsa%brc,this%gsa%btc,this%gsa%bpc,&
              &          this%gsa%cbtc,this%gsa%cbpc,fconvLMr,fkinLMr,      &
              &          fviscLMr,fpoynLMr,fresLMr,nR,1 )
      end if

      !-- Kinetic energy parallel and perpendicular to rotation axis
      if ( this%lPerpParCalc ) then
         EperpLMr(:)   =0.0_cp
         EparLMr(:)    =0.0_cp
         EperpaxiLMr(:)=0.0_cp
         EparaxiLMr(:) =0.0_cp
         call get_perpPar(this%gsa%vrc,this%gsa%vtc,this%gsa%vpc,EperpLMr, &
              &           EparLMr,EperpaxiLMr,EparaxiLMr,nR,1 )
      end if


      !--------- Movie output:
      if ( this%l_frame .and. l_movie_oc .and. l_store_frame ) then
         call store_movie_frame(this%nR,this%gsa%vrc,this%gsa%vtc,this%gsa%vpc, &
              &                 this%gsa%brc,this%gsa%btc,this%gsa%bpc,         &
              &                 this%gsa%sc,this%gsa%drSc,this%gsa%dvrdpc,      &
              &                 this%gsa%dvpdrc,this%gsa%dvtdrc,this%gsa%dvrdtc,&
              &                 this%gsa%cvrc,this%gsa%cbrc,this%gsa%cbtc,1,    &
              &                 this%sizeThetaB,this%leg_helper%bCMB)
      end if


      !--------- Stuff for special output:
      !--------- Calculation of magnetic field production and advection terms
      !          for graphic output:
      if ( l_dtB ) then
         call get_dtBLM(this%nR,this%gsa%vrc,this%gsa%vtc,this%gsa%vpc,       &
              &         this%gsa%brc,this%gsa%btc,this%gsa%bpc,               &
              &         1 ,this%sizeThetaB,this%dtB_arrays%BtVrLM,            &
              &         this%dtB_arrays%BpVrLM,this%dtB_arrays%BrVtLM,        &
              &         this%dtB_arrays%BrVpLM,this%dtB_arrays%BtVpLM,        &
              &         this%dtB_arrays%BpVtLM,this%dtB_arrays%BrVZLM,        &
              &         this%dtB_arrays%BtVZLM,this%dtB_arrays%BtVpCotLM,     &
              &         this%dtB_arrays%BpVtCotLM,this%dtB_arrays%BtVZcotLM,  &
              &         this%dtB_arrays%BtVpSn2LM,this%dtB_arrays%BpVtSn2LM,  &
              &         this%dtB_arrays%BtVZsn2LM)
      end if


      !--------- Torsional oscillation terms:
      PERFON('TO_terms')
      if ( ( this%lTONext .or. this%lTONext2 ) .and. l_mag ) then
         call getTOnext(this%leg_helper%zAS,this%gsa%brc,this%gsa%btc,     &
              &         this%gsa%bpc,this%lTONext,this%lTONext2,dt,dtLast, &
              &         this%nR,1,this%sizeThetaB,this%BsLast,this%BpLast, &
              &         this%BzLast)
      end if

      if ( this%lTOCalc ) then
         call getTO(this%gsa%vrc,this%gsa%vtc,this%gsa%vpc,this%gsa%cvrc,   &
              &     this%gsa%dvpdrc,this%gsa%brc,this%gsa%btc,this%gsa%bpc, &
              &     this%gsa%cbrc,this%gsa%cbtc,this%BsLast,this%BpLast,    &
              &     this%BzLast,this%TO_arrays%dzRstrLM,                    &
              &     this%TO_arrays%dzAstrLM,this%TO_arrays%dzCorLM,         &
              &     this%TO_arrays%dzLFLM,dtLast,this%nR,1,this%sizeThetaB)
      end if
      PERFOFF

      lorentz_torque_ic = lorentz_torques_ic
      this%lorentz_torque_ic = lorentz_torques_ic
      lorentz_torque_ma = this%lorentz_torque_ma

      if (DEBUG_OUTPUT) then
         call this%nl_lm%output()
      end if

      !-- Partial calculation of time derivatives (horizontal parts):
      !   input flm...  is in (l,m) space at radial grid points this%nR !
      !   Only dVxBh needed for boundaries !
      !   get_td finally calculates the d*dt terms needed for the
      !   time step performed in s_LMLoop.f . This should be distributed
      !   over the different models that s_LMLoop.f parallelizes over.
      !write(*,"(A,I4,2ES20.13)") "before_td: ", &
      !     &  this%nR,sum(real(conjg(VxBtLM)*VxBtLM)),sum(real(conjg(VxBpLM)*VxBpLM))
      !PERFON('get_td')
      call td_counter%start_count()
      call this%nl_lm%get_td(this%nR, this%nBc, this%lRmsCalc,           &
           &                 this%lPressCalc, dVSrLM, dVXirLM,           &
           &                 dVxVhLM, dVxBhLM, dwdt, dzdt, dpdt, dsdt,   &
           &                 dxidt, dbdt, djdt)
      call td_counter%stop_count(l_increment=.false.)

      !PERFOFF
      !write(*,"(A,I4,ES20.13)") "after_td:  ", &
      !     & this%nR,sum(real(conjg(dVxBhLM(:,this%nR_Mag))*dVxBhLM(:,this%nR_Mag)))
      !-- Finish calculation of TO variables:
      if ( this%lTOcalc ) then
         call getTOfinish(this%nR, dtLast, this%leg_helper%zAS,             &
              &           this%leg_helper%dzAS, this%leg_helper%ddzAS,      &
              &           this%TO_arrays%dzRstrLM, this%TO_arrays%dzAstrLM, &
              &           this%TO_arrays%dzCorLM, this%TO_arrays%dzLFLM)
      end if

      !--- Form partial horizontal derivaties of magnetic production and
      !    advection terms:
      if ( l_dtB ) then
         PERFON('dtBLM')
         call get_dH_dtBLM(this%nR,this%dtB_arrays%BtVrLM,this%dtB_arrays%BpVrLM,&
              &            this%dtB_arrays%BrVtLM,this%dtB_arrays%BrVpLM,        &
              &            this%dtB_arrays%BtVpLM,this%dtB_arrays%BpVtLM,        &
              &            this%dtB_arrays%BrVZLM,this%dtB_arrays%BtVZLM,        &
              &            this%dtB_arrays%BtVpCotLM,this%dtB_arrays%BpVtCotLM,  &
              &            this%dtB_arrays%BtVpSn2LM,this%dtB_arrays%BpVtSn2LM)
         PERFOFF
      end if
    end subroutine do_iteration_ThetaBlocking_shtns
!-------------------------------------------------------------------------------
   subroutine transform_to_grid_space_shtns(this, gsa, time)

      class(rIterThetaBlocking_shtns_t) :: this
      type(grid_space_arrays_t) :: gsa
      real(cp), intent(in) :: time

      integer :: nR
      nR = this%nR

      if ( l_conv .or. l_mag_kin ) then
         if ( l_heat ) then
            call scal_to_spat(s_Rloc(:,nR), gsa%sc)
            if ( this%lViscBcCalc ) then
               call scal_to_grad_spat(s_Rloc(:,nR), gsa%dsdtc, gsa%dsdpc)
               if (this%nR == n_r_cmb .and. ktops==1) then
                  gsa%dsdtc=0.0_cp
                  gsa%dsdpc=0.0_cp
               end if
               if (this%nR == n_r_icb .and. kbots==1) then
                  gsa%dsdtc=0.0_cp
                  gsa%dsdpc=0.0_cp
               end if
            end if
         end if

         if ( this%lRmsCalc ) then
            call scal_to_grad_spat(p_Rloc(:,nR), gsa%dpdtc, gsa%dpdpc)
         end if

         !-- Pressure
         if ( this%lPressCalc ) call scal_to_spat(p_Rloc(:,nR), gsa%pc)

         !-- Composition
         if ( l_chemical_conv ) call scal_to_spat(xi_Rloc(:,nR), gsa%xic)

         if ( l_HT .or. this%lViscBcCalc ) then
            call scal_to_spat(ds_Rloc(:,nR), gsa%drsc)
         endif
         if ( this%nBc == 0 ) then ! Bulk points
            !-- pol, sph, tor > ur,ut,up
            call torpol_to_spat(w_Rloc(:,nR), dw_Rloc(:,nR),  z_Rloc(:,nR), &
                 &              gsa%vrc, gsa%vtc, gsa%vpc)

            !-- Advection is treated as u \times \curl u
            if ( l_adv_curl ) then
               !-- z,dz,w,dd< -> wr,wt,wp
               call torpol_to_curl_spat(or2(nR), w_Rloc(:,nR), ddw_Rloc(:,nR), &
                    &                   z_Rloc(:,nR), dz_Rloc(:,nR),           &
                    &                   gsa%cvrc, gsa%cvtc, gsa%cvpc)

               !-- For some outputs one still need the other terms
               if ( this%lViscBcCalc .or. this%lPowerCalc .or.  &
               &    this%lFluxProfCalc .or. this%lTOCalc .or.   &
               &    ( this%l_frame .and. l_movie_oc .and. l_store_frame) ) then

                  call torpol_to_spat(dw_Rloc(:,nR), ddw_Rloc(:,nR),         &
                       &              dz_Rloc(:,nR), gsa%dvrdrc, gsa%dvtdrc, &
                       &              gsa%dvpdrc)
                  call pol_to_grad_spat(w_Rloc(:,nR),gsa%dvrdtc,gsa%dvrdpc)
                  call torpol_to_dphspat(dw_Rloc(:,nR),  z_Rloc(:,nR), &
                       &                 gsa%dvtdpc, gsa%dvpdpc)
               end if

            else ! Advection is treated as u\grad u

               call torpol_to_spat(dw_Rloc(:,nR), ddw_Rloc(:,nR), dz_Rloc(:,nR), &
                 &              gsa%dvrdrc, gsa%dvtdrc, gsa%dvpdrc)

               call pol_to_curlr_spat(z_Rloc(:,nR), gsa%cvrc)

               call pol_to_grad_spat(w_Rloc(:,nR), gsa%dvrdtc, gsa%dvrdpc)
               call torpol_to_dphspat(dw_Rloc(:,nR),  z_Rloc(:,nR), &
                    &                 gsa%dvtdpc, gsa%dvpdpc)
            end if

         else if ( this%nBc == 1 ) then ! Stress free
             ! TODO don't compute vrc as it is set to 0 afterward
            call torpol_to_spat(w_Rloc(:,nR), dw_Rloc(:,nR),  z_Rloc(:,nR), &
                 &              gsa%vrc, gsa%vtc, gsa%vpc)
            gsa%vrc = 0.0_cp
            if ( this%lDeriv ) then
               gsa%dvrdtc = 0.0_cp
               gsa%dvrdpc = 0.0_cp
               call torpol_to_spat(dw_Rloc(:,nR), ddw_Rloc(:,nR), dz_Rloc(:,nR), &
                    &              gsa%dvrdrc, gsa%dvtdrc, gsa%dvpdrc)
               call pol_to_curlr_spat(z_Rloc(:,nR), gsa%cvrc)
               call torpol_to_dphspat(dw_Rloc(:,nR),  z_Rloc(:,nR), &
                    &                 gsa%dvtdpc, gsa%dvpdpc)
            end if
         else if ( this%nBc == 2 ) then
            if ( this%nR == n_r_cmb ) then
               call v_rigid_boundary(this%nR,this%leg_helper%omegaMA,this%lDeriv, &
                    &                gsa%vrc,gsa%vtc,gsa%vpc,gsa%cvrc,gsa%dvrdtc, &
                    &                gsa%dvrdpc,gsa%dvtdpc,gsa%dvpdpc,            &
                    &                1,time)
            else if ( this%nR == n_r_icb ) then
               call v_rigid_boundary(this%nR,this%leg_helper%omegaIC,this%lDeriv, &
                    &                gsa%vrc,gsa%vtc,gsa%vpc,gsa%cvrc,gsa%dvrdtc, &
                    &                gsa%dvrdpc,gsa%dvtdpc,gsa%dvpdpc,            &
                    &                1,time)
            end if
            if ( this%lDeriv ) then
               call torpol_to_spat(dw_Rloc(:,nR), ddw_Rloc(:,nR), dz_Rloc(:,nR), &
                    &              gsa%dvrdrc, gsa%dvtdrc, gsa%dvpdrc)
            end if
         end if
      end if

      if ( l_mag .or. l_mag_LF ) then
         call torpol_to_spat(b_Rloc(:,nR), db_Rloc(:,nR),  aj_Rloc(:,nR),    &
              &              gsa%brc, gsa%btc, gsa%bpc)

         if ( this%lDeriv ) then
            call torpol_to_curl_spat(or2(nR), b_Rloc(:,nR), ddb_Rloc(:,nR), &
                 &                   aj_Rloc(:,nR), dj_Rloc(:,nR),          &
                 &                   gsa%cbrc, gsa%cbtc, gsa%cbpc)
         end if
      end if

   end subroutine transform_to_grid_space_shtns
!-------------------------------------------------------------------------------
   subroutine transform_to_lm_space_shtns(this, gsa, nl_lm)

      class(rIterThetaBlocking_shtns_t) :: this
      type(grid_space_arrays_t) :: gsa
      type(nonlinear_lm_t) :: nl_lm

      ! Local variables
      integer :: nTheta, nPhi, nThStart, nThStop

      call shtns_load_cfg(1)

      if ( (.not.this%isRadialBoundaryPoint .or. this%lRmsCalc) &
            .and. ( l_conv_nl .or. l_mag_LF ) ) then

         !$omp parallel default(shared) private(nThStart,nThStop,nTheta,nPhi)
         nThStart=1; nThStop=n_theta_max
         call get_openmp_blocks(nThStart,nThStop)

         !PERFON('inner1')
         if ( l_conv_nl .and. l_mag_LF ) then
            if ( this%nR>n_r_LCR ) then
               do nTheta=nThStart, nThStop
                  do nPhi=1, n_phi_max
                     gsa%Advr(nPhi, nTheta)=gsa%Advr(nPhi, nTheta) + gsa%LFr(nPhi, nTheta)
                     gsa%Advt(nPhi, nTheta)=gsa%Advt(nPhi, nTheta) + gsa%LFt(nPhi, nTheta)
                     gsa%Advp(nPhi, nTheta)=gsa%Advp(nPhi, nTheta) + gsa%LFp(nPhi, nTheta)
                  end do
               end do
            end if
         else if ( l_mag_LF ) then
            if ( this%nR > n_r_LCR ) then
               do nTheta=nThStart, nThStop
                  do nPhi=1, n_phi_max
                     gsa%Advr(nPhi, nTheta) = gsa%LFr(nPhi, nTheta)
                     gsa%Advt(nPhi, nTheta) = gsa%LFt(nPhi, nTheta)
                     gsa%Advp(nPhi, nTheta) = gsa%LFp(nPhi, nTheta)
                  end do
               end do
            else
               do nTheta=nThStart, nThStop
                  do nPhi=1, n_phi_max
                     gsa%Advr(nPhi,nTheta)=0.0_cp
                     gsa%Advt(nPhi,nTheta)=0.0_cp
                     gsa%Advp(nPhi,nTheta)=0.0_cp
                  end do
               end do
            end if
         end if

         if ( l_precession ) then
            do nTheta=nThStart, nThStop
               do nPhi=1, n_phi_max
                  gsa%Advr(nPhi, nTheta)=gsa%Advr(nPhi, nTheta) + gsa%PCr(nPhi, nTheta)
                  gsa%Advt(nPhi, nTheta)=gsa%Advt(nPhi, nTheta) + gsa%PCt(nPhi, nTheta)
                  gsa%Advp(nPhi, nTheta)=gsa%Advp(nPhi, nTheta) + gsa%PCp(nPhi, nTheta)
               end do
            end do
         end if

         if ( l_centrifuge ) then
            do nTheta=nThStart, nThStop
               do nPhi=1, n_phi_max
                  gsa%Advr(nPhi, nTheta)=gsa%Advr(nPhi, nTheta) + gsa%CAr(nPhi, nTheta)
                  gsa%Advt(nPhi, nTheta)=gsa%Advt(nPhi, nTheta) + gsa%CAt(nPhi, nTheta)
               end do
            end do
         end if
         !$omp end parallel

         call spat_to_SH(gsa%Advr, nl_lm%AdvrLM)
         call spat_to_SH(gsa%Advt, nl_lm%AdvtLM)
         call spat_to_SH(gsa%Advp, nl_lm%AdvpLM)

         if ( this%lRmsCalc .and. l_mag_LF .and. this%nR>n_r_LCR ) then
            ! LF treated extra:
            call spat_to_SH(gsa%LFr, nl_lm%LFrLM)
            call spat_to_SH(gsa%LFt, nl_lm%LFtLM)
            call spat_to_SH(gsa%LFp, nl_lm%LFpLM)
         end if
         !PERFOFF
      end if
      if ( (.not.this%isRadialBoundaryPoint) .and. l_heat ) then
         !PERFON('inner2')
         call spat_to_qst(gsa%VSr, gsa%VSt, gsa%VSp, nl_lm%VSrLM, nl_lm%VStLM, &
              &           nl_lm%VSpLM)

         if (l_anel) then ! anelastic stuff
            if ( l_mag_nl .and. this%nR>n_r_LCR ) then
               call spat_to_SH(gsa%ViscHeat, nl_lm%ViscHeatLM)
               call spat_to_SH(gsa%OhmLoss, nl_lm%OhmLossLM)
            else
               call spat_to_SH(gsa%ViscHeat, nl_lm%ViscHeatLM)
            end if
         end if
         !PERFOFF
      end if
      if ( (.not.this%isRadialBoundaryPoint) .and. l_chemical_conv ) then
         call spat_to_qst(gsa%VXir, gsa%VXit, gsa%VXip, nl_lm%VXirLM, &
              &           nl_lm%VXitLM, nl_lm%VXipLM)
      end if
      if ( l_mag_nl ) then
         !PERFON('mag_nl')
         if ( .not.this%isRadialBoundaryPoint .and. this%nR>n_r_LCR ) then
            call spat_to_qst(gsa%VxBr, gsa%VxBt, gsa%VxBp, nl_lm%VxBrLM, &
                 &           nl_lm%VxBtLM, nl_lm%VxBpLM)
         else
            call spat_to_sphertor(gsa%VxBt,gsa%VxBp,nl_lm%VxBtLM,nl_lm%VxBpLM)
         end if
         !PERFOFF
      end if

      if ( this%lRmsCalc ) then
         call spat_to_sphertor(gsa%dpdtc, gsa%dpdpc, nl_lm%PFt2LM, nl_lm%PFp2LM)
         call spat_to_sphertor(gsa%CFt2, gsa%CFp2, nl_lm%CFt2LM, nl_lm%CFp2LM)
         call spat_to_qst(gsa%dtVr, gsa%dtVt, gsa%dtVp, nl_lm%dtVrLM, &
              &           nl_lm%dtVtLM, nl_lm%dtVpLM)
         if ( l_conv_nl ) then
            call spat_to_sphertor(gsa%Advt2, gsa%Advp2, nl_lm%Advt2LM, nl_lm%Advp2LM)
         end if
         if ( l_mag_nl .and. this%nR>n_r_LCR ) then
            call spat_to_sphertor(gsa%LFt2, gsa%LFp2, nl_lm%LFt2LM, nl_lm%LFp2LM)
         end if
      end if

      call shtns_load_cfg(0)

   end subroutine transform_to_lm_space_shtns
!-------------------------------------------------------------------------------
end module rIterThetaBlocking_shtns_mod

! Initialise Markov chains
!
module m_initialise

    use iso_c_binding
    use omp_lib
#ifdef MPI
    use mpi
#endif

    use m_logger,       only : log_msg
    use m_exception,    only : exception_raiseError
    use m_utils,        only : ii10, itoa, rtoa, vs2vp, vp2rho, results_dir, init_random_seed, &
                               init_random_seed_internal,last_dir, resume_dir, ini_dir, FILEDIR_SEPARATOR, create_dir
    use m_likelihood,   only : likelihood, T_LIKE, like_setup
    use mt19937,        only : grnd, init_genrand, unirand
    use m_settings,     only : T_MCMC_SET, T_GRID, T_MOD, mod_setup, settings_check
    use like_settings,  only : T_DATA, T_LIKE_SET, read_data, read_sources, T_LIKE_BASE, likeBaseSetup
    use run_info,       only : T_SAMPLE, init_samples, init_sample, T_RUN_INFO,&
                               init_run_info, read_info, write_info, read_samples, write_samples
    use m_mcmc,         only : kdtree_to_grid  


    use m_hmcmc
    use read_write

#ifdef NETCDF
    use netcdf_read_write, only : netcdf_create_file, netcdf_write, T_NC, init_nc_model
#endif
            
    implicit none

    private

    public :: initialise


    ! static value
    real(kind=ii10), parameter :: eps = 1E10*tiny(0.0_ii10)

contains

    subroutine initialise(RTI,dat,mcmc_set,like_set)
        implicit none
        type(T_RUN_INFO), intent(out) :: RTI
        type(T_DATA), dimension(:), allocatable, intent(out) :: dat
        type(T_MCMC_SET), intent(in) :: mcmc_set
        type(T_LIKE_SET), intent(in) :: like_set

        ! local variable
        ! likelihood
        type(T_LIKE)        :: initial_like

        ! mcmc
        type(T_SAMPLE), dimension(:), allocatable :: samples
        type(T_HMC_SAMPLES) :: hmcsamples
        real(kind=ii10), dimension(:,:), allocatable :: temperatures
        type(T_RUN_INFO) :: rti_last
        logical lexist

        ! Voronoi tessellation and grid information
        type(T_GRID) :: grid
        type(T_MOD)  :: model

        ! initialisation
        integer ranseed, nproc

        ! random
        real(kind=ii10) random

        ! cpu time
        real(kind=ii10) t1, t2

        ! iterator
        integer(kind=c_size_t) i

        ! mpi
        integer ierror

        ! check settings first
        call settings_check(mcmc_set)

        ! read data from files
        call log_msg('Reading sources, receivers and travel times...')
        if(mcmc_set%datatype == 3)then
            allocate(dat(2))
        else
            allocate(dat(1))
        endif
        call read_data(dat,like_set)

        ! create folders for results
#ifdef MPI
        call mpi_barrier(mpi_comm_world,ierror)
        call mpi_comm_size(mpi_comm_world,nproc,ierror)
        if(mcmc_set%processor==1 .or. nproc==1)then
#endif
        if( create_dir(trim(results_dir)) == -1)&
            call exception_raiseError('Error creating the results folder &
            &'//trim(results_dir))
        if( create_dir(trim(last_dir)) == -1)&
            call exception_raiseError('Error creating the last run folder &
            &'//trim(last_dir))
        if( create_dir(trim(resume_dir)) == -1)&
            call exception_raiseError('Error creating the resume folder &
            &'//trim(resume_dir))
        if( create_dir(trim(ini_dir)) == -1)&
            call exception_raiseError('Error creating the ini folder &
            &'//trim(ini_dir))
#ifdef MPI
        endif
#endif

        ! initialise random generator
        ranseed = mcmc_set%processor
        call init_genrand(init_random_seed(ranseed))
        call init_random_seed_internal(ranseed)
        !call init_genrand(ranseed)
        call log_msg('Ranseed= ' // itoa(ranseed) )

        !
        ! generate initial model and initialise run time information
        !
        call init_run_info(RTI,dat,mcmc_set)
        ! read temperatures
        if(mcmc_set%tempering == 1)then
            call read_temperatures0(trim(mcmc_set%temperfile),&
                RTI%temperature_values0,mcmc_set%number_of_1s+1)
            RTI%temperature_indices = RTI%temperature_indices0
            RTI%temperature_values = RTI%temperature_values0
        endif

        
        ! first, do some initialisation
        grid = mcmc_set%grid
        call like_setup(initial_like,dat,like_set,mcmc_set%ncell_max ) 

        ! Draw the first model based on resume mode or not
        select case(mcmc_set%resume)
        case(1)
            t1 = omp_get_wtime()
            if(mcmc_set%initialise==1)then
                call read_txt_vertices(RTI,mcmc_set%initial_model)
                call mod_setup(model, grid)
                call kdtree_to_grid(RTI, grid, model)
                call likelihood( dat,RTI,like_set,initial_like )
                if( abs(initial_like%like-huge(initial_like%like)) < eps )then
                    call exception_raiseError('The initial model cannot&
                        & generate valid data!')
                endif
            else
                call generate_model(RTI,dat,mcmc_set,like_set,initial_like)
            endif
            t2 =  omp_get_wtime()
            call log_msg('Generating an initial model takes: '// rtoa(t2-t1) )
            ! write out the inital sample
            call write_initial_sample(RTI,ranseed)
            ! write the first sample
            allocate(samples(1))
            call init_samples(samples)
            samples(1)%ncells = RTI%ncells
            samples(1)%misfit = initial_like%misfit
            samples(1)%unweighted_misfit = initial_like%unweighted_misfit
            samples(1)%like = initial_like%like
            ! wirte the first sample
            call write_likelihood(trim(results_dir)//FILEDIR_SEPARATOR//'likelihood_'//itoa(mcmc_set%processor)//'.dat',samples)
            call write_number_of_cells(trim(results_dir)//FILEDIR_SEPARATOR//'ncells_'//itoa(mcmc_set%processor)//'.dat',samples)
            ! create netcdf file and initialize it
#ifdef NETCD
            call init_nc_model(nc_model,mcmc_set,RTI)
            call netcdf_create_file(trim(results_dir)//FILEDIR_SEPARATOR//'samples_'//itoa(ranseed)//'.nc',nc_model,samples(1))
#endif
        case(2:)
            ! read initial delaunay triangulation from file
            call log_msg('reading last delaunay triangulation vertex...')
            call read_vertices(RTI,trim(last_dir)//FILEDIR_SEPARATOR//'last_vertices_'//itoa(ranseed)//'.dat' )
            ! read some parameters from file
            ! read_parameters
            call read_info(RTI,trim(last_dir)//FILEDIR_SEPARATOR//'last_info_'//itoa(ranseed)//'.dat')
            ! nsamples should be reinitialized
            RTI%nsamples = mcmc_set%nsamples
            RTI%nsampled = 0
            ! read mean&variance
            call read_mean(RTI,trim(last_dir)//FILEDIR_SEPARATOR//'last_average_'//itoa(ranseed)//'.dat')
            call read_var(RTI,trim(last_dir)//FILEDIR_SEPARATOR//'last_var_'//itoa(ranseed)//'.dat')
            ! reinitialize average, std and nthin if requested
            if(mcmc_set%burn_in >= RTI%sampletotal)then
                call log_msg('Burn-in is resetted to '// itoa(mcmc_set%burn_in) )
                RTI%nthin = 0
                RTI%aveP = 0
                RTI%stdP = 0
                RTI%aveS = 0
                RTI%stdS = 0
            endif
            ! do the random number generator
            do i = 1, RTI%randcount
                random = grnd()
            enddo
        case(0)
            ! resume the last run which exited unnormaly
            call log_msg('Trying to resume the interrupted run...')
            ! read the last saved info
            call read_info(RTI,trim(resume_dir)//FILEDIR_SEPARATOR//'run_time_info_'//itoa(ranseed)//'.dat')
            ! read the last running info to check resume is necessary or not
            inquire(file=trim(last_dir)//FILEDIR_SEPARATOR//'last_info_'//itoa(ranseed)//'.dat',exist=lexist)
            if(lexist)then
                call init_run_info(rti_last,dat,mcmc_set)
                call read_info(rti_last,trim(last_dir)//FILEDIR_SEPARATOR//'last_info_'//itoa(ranseed)//'.dat')
                if(rti_last%sampletotal>=rti%sampletotal)&
                    call exception_raiseError('No need to resume the running, please restart it with resume=2')
            endif
            ! read and save already sampled samples
            if(mcmc_set%hmc /= 1)then
                allocate(samples(RTI%nsampled))
                call init_samples(samples)
                call read_samples(samples,trim(resume_dir)//FILEDIR_SEPARATOR//'run_time_sample_'//itoa(ranseed)//'.dat')
                call write_samples(trim(results_dir)//FILEDIR_SEPARATOR//'samples_'//itoa(ranseed)//'.out',samples)
                call write_likelihood(trim(results_dir)//FILEDIR_SEPARATOR//'likelihood_'//itoa(ranseed)//'.dat',samples)
                call write_number_of_cells(trim(results_dir)//FILEDIR_SEPARATOR//'ncells_'//itoa(ranseed)//'.dat',samples)
#ifdef NETCDF
                call netcdf_write(trim(results_dir)//FILEDIR_SEPARATOR//'samples_'//itoa(ranseed)//'.nc',samples)
#endif
                deallocate(samples)
            else
                call create_hmcsamples(hmcsamples,RTI%nsampled,mcmc_set)
                call read_hmcsamples(hmcsamples,trim(resume_dir)//FILEDIR_SEPARATOR//'run_time_sample_'//itoa(ranseed)//'.dat')
                call write_hmcsamples(hmcsamples,trim(results_dir)//FILEDIR_SEPARATOR//'hmcsamples_'//itoa(ranseed)//'.dat')
                call write_likelihood_hmc(hmcsamples,trim(results_dir)//FILEDIR_SEPARATOR//'likelihood_'//itoa(ranseed)//'.dat')
                call write_number_of_cells_hmc(hmcsamples,trim(results_dir)//FILEDIR_SEPARATOR//'ncells_'//itoa(ranseed)//'.dat')

            endif
            ! if tempering, read and save already sampled tempratures
            if(mcmc_set%tempering == 1)then
                allocate( temperatures(4,RTI%nsampled) )
                temperatures = 0
                call read_temperatures(trim(resume_dir)//FILEDIR_SEPARATOR//'run_time_temperatures_'//itoa(mcmc_set%processor)//'.dat',temperatures)
                call write_temperatures(trim(results_dir)//FILEDIR_SEPARATOR//'temperatures_'//itoa(mcmc_set%processor)//'.dat',temperatures)
                deallocate(temperatures)
            endif
            ! read the last saved vertices
            call read_vertices(RTI,trim(resume_dir)//FILEDIR_SEPARATOR//'run_time_vertices_'//itoa(ranseed)//'.dat' )
            ! nsamples should be reinitialized
            RTI%nsamples = RTI%nsamples - RTI%nsampled
            RTI%nsampled = 0
            ! read mean&variance
            call read_mean(RTI,trim(resume_dir)//FILEDIR_SEPARATOR//'run_time_average_'//itoa(ranseed)//'.dat')
            call read_var(RTI,trim(resume_dir)//FILEDIR_SEPARATOR//'run_time_var_'//itoa(ranseed)//'.dat')
            ! do the random number generator
            do i = 1, RTI%randcount
                random = grnd()
            enddo
        case default
            call exception_raiseError("The number of sampling cannot less than 0")
        end select

    endsubroutine initialise

    subroutine generate_model(RTI,dat,mcmc_set,like_set,initial_like)
        implicit none
        type(T_RUN_INFO), intent(inout) :: RTI
        type(T_DATA), dimension(:), intent(in) :: dat
        type(T_MCMC_SET), intent(in)   :: mcmc_set
        type(T_LIKE_SET), intent(in)   :: like_set
        type(T_LIKE), intent(inout)    :: initial_like

        ! local variable
        ! Voronoi tessellation and grid information
        type(T_GRID) :: grid
        type(T_MOD) :: model

        ! initialisation
        integer initial_ncells
        integer, parameter :: max_init_num =  1000
        integer :: count_init_num =  1000

        ! cpu time
        integer i

        ! initial grid
        grid = mcmc_set%grid
        ! propose an initial model
        call log_msg('Generating an initial model...')
        initial_ncells = int( mcmc_set%ncell_min+unirand(RTI%randcount)*(mcmc_set%ncell_max-mcmc_set%ncell_min) )
        RTI%ncells = initial_ncells
        call mod_setup(model, grid)
        call like_setup(initial_like,dat,like_set,mcmc_set%ncell_max ) 
    
        ! generating an realistic initial model (discard those failed to find an eigenvalue)
        count_init_num = 0
        do while( abs(initial_like%like-huge(initial_like%like)) < EPS .and. &
                count_init_num < max_init_num)
            call log_msg('Generating...')
            count_init_num =  count_init_num + 1
            do i = 1, initial_ncells
                RTI%points(1,i) = grid%xmin + unirand(RTI%randcount)*(grid%xmax-grid%xmin)
                RTI%points(2,i) = grid%ymin + unirand(RTI%randcount)*(grid%ymax-grid%ymin)

                ! if using surface waves, set the initial vs model as increasing
                ! with depth to ensure generating reasonable data. Considering
                ! real earth strucutre, this is not a bad initial model at all.
                if(mcmc_set%datatype<=1)then
                    RTI%parameters(2,i) = mcmc_set%vsmin + unirand(RTI%randcount)*(mcmc_set%vsmax-mcmc_set%vsmin)
                    RTI%parameters(1,i) = mcmc_set%vpmin + unirand(RTI%randcount)*(mcmc_set%vpmax-mcmc_set%vpmin)
                    !RTI%parameters(1,i) = mcmc_set%vpmin + (RTI%points(2,i)-grid%ymin)*&
                    !    (mcmc_set%vpmax-mcmc_set%vpmin)/(grid%ymax-grid%ymin)
                    !RTI%parameters(1,i) = vs2vp(RTI%parameters(2,i))
                    ! debug test
                    !RTI%parameters(2,i) = 2.0
                    !RTI%parameters(1,i) = 3.5
                else
                    RTI%parameters(2,i) = mcmc_set%init_vsmin + (RTI%points(2,i)-grid%ymin)*&
                        (mcmc_set%init_vsmax-mcmc_set%init_vsmin)/(grid%ymax-grid%ymin)
                    !RTI%parameters(1,i) = mcmc_set%vpmin + unirand(RTI%randcount)*(mcmc_set%vpmax-mcmc_set%vpmin)
                    RTI%parameters(1,i) = vs2vp(RTI%parameters(2,i))
                endif
                !parameters(i)%vp = vs2vp(parameters(i)%vs)
                RTI%parameters(3,i) = vp2rho(RTI%parameters(1,i))
            enddo
    
            call kdtree_to_grid(RTI, grid, model)
            call likelihood( dat, RTI,like_set,initial_like)
        enddo

    endsubroutine generate_model

end module m_initialise

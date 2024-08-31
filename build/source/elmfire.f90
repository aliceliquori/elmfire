! *****************************************************************************
PROGRAM ELMFIRE
! *****************************************************************************

USE ELMFIRE_CALIBRATION
USE ELMFIRE_IGNITION
USE ELMFIRE_IO
USE ELMFIRE_SUBS
USE ELMFIRE_VARS
USE ELMFIRE_LEVEL_SET
USE ELMFIRE_SPOTTING
USE ELMFIRE_NAMELISTS
USE ELMFIRE_INIT
USE MPI_F08
USE, INTRINSIC :: ISO_C_BINDING, ONLY : C_PTR, C_F_POINTER

IMPLICIT NONE

INTEGER :: COLOR, I, IASP, IBAND, IBIN, ICASE, ICASE_RECV, ICOL, IDEST=0, IERR=0, IOS, &
           IRANK_TO_RUN_METEOROLOGY_BAND(0:10000)=-1,  IWX_BAND, IWX_BAND_LAST=-9999, &
           IRANK_FROM, IROW, J, IT1, IT2, IX, IY, IWD20_TIMES10, M, N, &
           NTIMESTEPS, TOTALCASESRUN

INTEGER, ALLOCATABLE, DIMENSION(:) :: K

LOGICAL :: GOOD_INPUTS

REAL :: APHIW, COSASPMPI, PHIMAG, PHIWX, PHIWY, PHIX, PHIY, SINASPMPI

CHARACTER(3) :: THREE_IWX_BAND
CHARACTER(60) :: VERSIONSTRING='ELMFIRE 2024.0831'
CHARACTER(400) :: FN, MESSAGESTR

TYPE (RASTER_TYPE), POINTER :: R

TYPE(RASTER_TYPE) SPREAD_RATE_TO_DUMP, FLAME_LENGTH_TO_DUMP, CROWN_FIRE_TO_DUMP
TYPE(DLL) :: LIST_FIRE_POTENTIAL
TYPE(NODE), POINTER :: C, DUMMY_NODE => NULL()

! Should move this elsewhere:
ALLOCATE (SUPP (0:1000))

! Initialize system clock for later use in profiling sections of code
CALL SYSTEM_CLOCK(COUNT_RATE=CLOCK_COUNT_RATE)
CALL SYSTEM_CLOCK(COUNT_MAX=CLOCK_COUNT_MAX)
CALL SYSTEM_CLOCK(IT1)
IT_START = IT1

CALL GET_OPERATING_SYSTEM ! Sets the following variables:
! OPERATING_SYSTEM  = 'linux  ' or 'windows'
! PATH_SEPARATOR    = '/' or '\'
! DELETECOMAND      =  '/bin/rm -f ' or 'del   '

! Initialize MPI. This creates the communicator MPI_COMM_WORLD which is used for message passing to 
! all processes on all hosts. Other variables that are set include:
! IRANK_WORLD: each process's rank across all hosts - it is unique 
! NPROC:  Total number of processes (i.e., the -np flag passed to mpirun)
CALL MPI_INIT(IERR)
CALL MPI_COMM_RANK(MPI_COMM_WORLD,IRANK_WORLD,IERR)
CALL MPI_COMM_SIZE(MPI_COMM_WORLD,NPROC,IERR)
CALL MPI_GET_PROCESSOR_NAME (PROCNAME,LENPROCNAME,IERR)

! Create separate MPI communicators on each host. This creates or sets:
! MPI_COMM_HOST:  Communicator for message passing on a single host
! IRANK_HOST:  each process's rank on that host - not unique across all hosts
! NPROC_HOST:  the number of processes on a host
CALL MPI_COMM_SPLIT_TYPE(MPI_COMM_WORLD, MPI_COMM_TYPE_SHARED, 0, MPI_INFO_NULL, MPI_COMM_HOST, IERR)
CALL MPI_COMM_RANK(MPI_COMM_HOST,IRANK_HOST,IERR)
CALL MPI_COMM_SIZE(MPI_COMM_HOST,NPROC_HOST,IERR)

! Store the number of processors on the host where IRANK_WORLD = 0 and broadcase to all hosts. 
! This is used later for parallel i/o in subroutine SETUP_PARALLEL_IO
IF (IRANK_WORLD .EQ. 0) NPROC_IRANK0 = NPROC_HOST
CALL MPI_BCAST(NPROC_IRANK0, 1, MPI_INTEGER, 0, MPI_COMM_WORLD, IERR)

! On each host, create the communicator MPI_COMM_HOST_IRANK0 for passing messages betwen all processes
! where IRANK_HOST = 0. This is used later to broadcast arrays from the host on which fuel and weather
! data is read from disk to all other hosts. 
IF (IRANK_HOST .EQ. 0) THEN
   COLOR=0
ELSE
   COLOR=1
ENDIF
CALL MPI_COMM_SPLIT(MPI_COMM_WORLD, COLOR, IRANK_WORLD, MPI_COMM_HOST_IRANK0, IERR)

! Initialize timings array for profiling:
TIMINGS_SIZE=0_MPI_ADDRESS_KIND
IF (IRANK_HOST .EQ. 0) TIMINGS_SIZE=INT(100*NPROC_HOST,MPI_ADDRESS_KIND)*4_MPI_ADDRESS_KIND
CALL MPI_WIN_ALLOCATE_SHARED (TIMINGS_SIZE, DISP_UNIT, MPI_INFO_NULL, MPI_COMM_HOST, TIMINGS_PTR, WIN_TIMINGS)
IF (IRANK_HOST .NE. 0) CALL MPI_WIN_SHARED_QUERY(WIN_TIMINGS, 0, TIMINGS_SIZE, DISP_UNIT, TIMINGS_PTR)
ARRAYSHAPE_TIMINGS=(/ NPROC_HOST, 100 /)
CALL C_F_POINTER(TIMINGS_PTR, TIMINGS, ARRAYSHAPE_TIMINGS)
IF (NPROC .GT. 1) CALL MPI_WIN_FENCE(0, WIN_TIMINGS, IERR)
IF (IRANK_HOST .EQ. 0) TIMINGS(:,:) = 0.

! Print version number:
IF (IRANK_WORLD .EQ. 0) WRITE(*,*) TRIM(VERSIONSTRING)

!Get input file name:
CALL GET_COMMAND_ARGUMENT(1,NAMELIST_FN)
IF (NAMELIST_FN(1:1)==' ') THEN
   WRITE(*,*) "Error, no input file specified."
   WRITE(*,*) "Hit Enter to continue."
   READ(5,*)
   STOP
ENDIF

! Open input file and read in namelist groups
OPEN(LUINPUT,FILE=TRIM(NAMELIST_FN),FORM='FORMATTED',STATUS='OLD',IOSTAT=IOS)
IF (IOS .GT. 0) THEN
   WRITE(*,*) 'Problem opening input file ', TRIM(NAMELIST_FN)
   STOP
ENDIF

! Read and check inputs
CALL READ_MISC
REWIND(LUINPUT); CALL READ_INPUTS
REWIND(LUINPUT); CALL READ_OUTPUTS
REWIND(LUINPUT); CALL READ_COMPUTATIONAL_DOMAIN
REWIND(LUINPUT); CALL READ_TIME_CONTROL
REWIND(LUINPUT); CALL READ_SIMULATOR
REWIND(LUINPUT); CALL READ_WUI
REWIND(LUINPUT); CALL READ_CALIBRATION
REWIND(LUINPUT); CALL READ_SUPPRESSION
REWIND(LUINPUT); CALL READ_SPOTTING
REWIND(LUINPUT); CALL READ_SMOKE
REWIND(LUINPUT); CALL READ_MONTE_CARLO ; NUM_ENSEMBLE_MEMBERS0 = NUM_ENSEMBLE_MEMBERS
CLOSE(LUINPUT)
IF (IRANK_WORLD .EQ. 0) CALL WRITE_FUEL_MODEL_TABLE
IF ( TRIM(FUEL_MODEL_FILE) .EQ. 'null') FUEL_MODEL_FILE='fuel_models.csv'
IF (TRIM(MISCELLANEOUS_INPUTS_DIRECTORY) .EQ. 'null' // PATH_SEPARATOR) MISCELLANEOUS_INPUTS_DIRECTORY=TRIM(FUELS_AND_TOPOGRAPHY_DIRECTORY) // PATH_SEPARATOR
CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)
CALL READ_FUEL_MODEL_TABLE
IF (USE_BLDG_SPREAD_MODEL .AND. BLDG_SPREAD_MODEL_TYPE .NE. 1) CALL READ_BUILDING_FUEL_MODEL_TABLE
CALL READ_CALIBRATION_BY_PYROME

IF (IRANK_WORLD .EQ. 0) THEN
   CALL CHECK_INPUTS(GOOD_INPUTS)
   IF (.NOT. GOOD_INPUTS) CALL SHUTDOWN()
ENDIF

! Initialize random number generator - this has to be done after inputs are read in
! because both SEED and RANDOMIZE_RANDOM_SEED are user-specified
CALL RANDOM_SEED(SIZE=M)
ALLOCATE(K(M))

IF (RANDOMIZE_RANDOM_SEED) THEN
   K(:) = (IT1/1000) * (IRANK_WORLD+1) * (/ (I, I = 1, M) /) !IT1 is from earlier call to SYSTEM_CLOCK
ELSE
   K(:) = SEED !+ IRANK_WORLD
ENDIF
CALL RANDOM_SEED(PUT=K(1:M))

CALL SUNRISE_SUNSET_CALCS (LONGITUDE, LATITUDE, CURRENT_YEAR, HOUR_OF_YEAR)

CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)
CALL ACCUMULATE_CPU_USAGE(2, IT1, IT2)

! Build lookup tables for trigonometric arrays, wind adjustment factor, nonburnable mask, etc.
CALL INIT_LOOKUP_TABLES

CALL SETUP_PARALLEL_IO

IF (IRANK_WORLD .EQ. 0) WRITE(*,*) 'Reading headers for fuels/topography and weather rasters'

IF (USE_TILED_IO) THEN
   IF (IRANK_WORLD .EQ. PARALLEL_IO_RANK(1)) THEN
      FN = TRIM(FUELS_AND_TOPOGRAPHY_DIRECTORY) // TRIM(ASP_FILENAME)
      CALL READ_BSQ_HEADER_EXISTING_TILED (ASP,FN)
   ENDIF
   IF (IRANK_WORLD .EQ. PARALLEL_IO_RANK(2)) THEN
      FN = TRIM(WEATHER_DIRECTORY) // TRIM(WS_FILENAME)
      CALL READ_BSQ_HEADER_EXISTING_TILED (WS,FN)
   ENDIF
ELSE
   IF (IRANK_WORLD .EQ. PARALLEL_IO_RANK(1)) THEN
      CALL READ_BSQ_HEADER (ASP, FUELS_AND_TOPOGRAPHY_DIRECTORY, ASP_FILENAME, .FALSE.)
   ENDIF

   IF (IRANK_WORLD .EQ. PARALLEL_IO_RANK(2)) THEN
      CALL READ_BSQ_HEADER (WS , WEATHER_DIRECTORY             , WS_FILENAME , .FALSE.)
   ENDIF
ENDIF

IF (NPROC .GT. 1) THEN
   CALL MPI_BCAST_RASTER_HEADER(ASP, PARALLEL_IO_RANK(1), .TRUE.)
   CALL MPI_BCAST_RASTER_HEADER(WS , PARALLEL_IO_RANK(2), .TRUE.)
ENDIF

CALL ACCUMULATE_CPU_USAGE(3, IT1, IT2)

IF (IRANK_WORLD .EQ. 0) WRITE(*,*) 'Setting up shared memory, part 1'
CALL SETUP_SHARED_MEMORY_1

CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)
CALL ACCUMULATE_CPU_USAGE(4, IT1, IT2)

IF (IRANK_WORLD .EQ. 0) WRITE(*,*) 'Reading weather, fuel, and topography rasters'

IF (USE_TILED_IO) THEN
   CALL READ_WEATHER_FUEL_TOPOGRAPHY_TILED
ELSE
   CALL READ_WEATHER_FUEL_TOPOGRAPHY
ENDIF

CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)
CALL ACCUMULATE_CPU_USAGE(5, IT1, IT2)

IF (MULTIPLE_HOSTS) CALL BCAST_WEATHER_FUEL_TOPOGRAPHY

IF (ABS(GRID_DECLINATION) .GT. 0.1 ) THEN
   IF (ROTATE_ASP) CALL ROTATE_ASP_AND_WD(1)
   IF (ROTATE_WD ) CALL ROTATE_ASP_AND_WD(2)
ENDIF

WHERE(FBFM%I2(:,:,1) .GT. 303) FBFM%I2(:,:,1) = 256
WHERE(FBFM%I2(:,:,1) .LT.   0) FBFM%I2(:,:,1) =  99

IF (USE_PYROMES .AND. ADJUSTMENT_FACTORS_BY_PYROME) THEN
   DO IY = 1, FBFM%NROWS
   DO IX = 1, FBFM%NCOLS
      IF (FBFM%I2(IX,IY,1) .LT. 101 .OR. FBFM%I2(IX,IY,1) .GT. 204) CYCLE
      IF (PYROMES%I2(IX,IY,1) .LT. 1 .OR. PYROMES%I2(IX,IY,1) .GT. 128) THEN
         ADJ%R4(IX,IY,1) = 1.0
      ELSE
         ADJ%R4(IX,IY,1) = ADJ_PYROME(PYROMES%I2(IX,IY,1),FBFM%I2(IX,IY,1))
      ENDIF
   ENDDO
   ENDDO
ENDIF

CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)
CALL ACCUMULATE_CPU_USAGE(6, IT1, IT2)

! Now that weather, fuel, topography are read in map fine inputs to coarse inputs
ALLOCATE(ICOL_ANALYSIS_F2C(1:ANALYSIS_NCOLS))
ALLOCATE(IROW_ANALYSIS_F2C(1:ANALYSIS_NROWS))
CALL MAP_FINE_TO_COARSE(WS, ASP, ICOL_ANALYSIS_F2C, IROW_ANALYSIS_F2C)

! Allocate additional rasters
IF (MODE .EQ. 1 .OR. MODE .EQ. 3) THEN
   IF (IRANK_WORLD .EQ. 0) WRITE(*,*) 'Allocating additional rasters'
   R=>ASP
   IF (DUMP_EMBER_FLUX) THEN
      CALL ALLOCATE_EMPTY_RASTER(EMBER_FLUX, R%NCOLS, R%NROWS, 1, R%XLLCORNER, R%YLLCORNER, R%CELLSIZE, 0., 'FLOAT     ')
   ENDIF

   IF (ENABLE_SPOTTING .AND. USE_UMD_SPOTTING_MODEL .AND. USE_EULERIAN_SPOTTING) THEN
      IF (BUILD_EMBER_FLUX_TABLE) THEN
         EMBER_FLUX_TABLE_LEN = CEILING((SIMULATION_TSTOP-SIMULATION_TSTART)/DT_DUMP_EMBER_FLUX)
      ELSE
         EMBER_FLUX_TABLE_LEN = 1
      ENDIF
      CALL ALLOCATE_EMPTY_RASTER(EMBER_FLUX, R%NCOLS, R%NROWS, EMBER_FLUX_TABLE_LEN, R%XLLCORNER, R%YLLCORNER, R%CELLSIZE, 0., 'FLOAT     ')
   ENDIF

   IF (IRANK_WORLD .GT. 0 .OR. (IRANK_WORLD .EQ. 0 .AND. NPROC .EQ. 1)) THEN
      CALL ALLOCATE_EMPTY_RASTER(ANALYSIS_SURFACE_FIRE, R%NCOLS, R%NROWS, 1, R%XLLCORNER, R%YLLCORNER, R%CELLSIZE, R%NODATA_VALUE, 'SIGNEDINT ')
   ENDIF
ENDIF

IF (IRANK_HOST .EQ. 0) CALL INIT_RASTERS

CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)
CALL ACCUMULATE_CPU_USAGE(7, IT1, IT2)

CALL ALLOCATE_IGNITION_ARRAYS
 
IF (RANDOM_IGNITIONS .AND. MODE .NE. 2) THEN
   IF (IRANK_WORLD .EQ. 0) THEN
      WRITE(*,*) 'Calculating NUM_CASES_TOTAL'
      IF (CSV_FIXED_IGNITION_LOCATIONS) THEN
         CALL DETERMINE_NUM_CASES_TOTAL_CSV
      ELSE
         CALL DETERMINE_NUM_CASES_TOTAL
      ENDIF
   ENDIF
   IF (NPROC .GT. 1) THEN
      CALL MPI_BCAST(NUM_CASES_TOTAL,                 1 , MPI_INTEGER, 0, MPI_COMM_WORLD, IERR)
      CALL MPI_BCAST(NUM_STARTING_WX_BANDS,           1 , MPI_INTEGER, 0, MPI_COMM_WORLD, IERR)
      CALL MPI_BCAST(NUM_CASES_PER_STARTING_WX_BAND(IWX_BAND_START:IWX_BAND_STOP), 1+(IWX_BAND_STOP-IWX_BAND_START) , MPI_INTEGER, 0, MPI_COMM_WORLD, IERR)
   ENDIF
ENDIF
IF (MODE .NE. 2 .AND. NUM_MONTE_CARLO_VARIABLES .GT. 0) ALLOCATE(COEFFS_UNSCALED_BY_CASE(1:NUM_CASES_TOTAL,1:NUM_MONTE_CARLO_VARIABLES))

CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)
CALL ACCUMULATE_CPU_USAGE(8, IT1, IT2)

IF (IRANK_WORLD .EQ. 0) WRITE(*,*) 'Setting up shared memory, part 2'
CALL SETUP_SHARED_MEMORY_2

CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)
CALL ACCUMULATE_CPU_USAGE(9, IT1, IT2)

IF (RANDOM_IGNITIONS .AND. IRANK_WORLD .EQ. 0 .AND. MODE .NE. 2) THEN
   WRITE(*,*) 'Done setting up shared memory. Determining random ignition locations'
   IF (CSV_FIXED_IGNITION_LOCATIONS) THEN
      DO ICASE = 1, NUM_CASES_TOTAL
         STATS_IWX_BAND_START(ICASE) = CSV_IBANDARR(ICASE) 
         STATS_X(ICASE) = CSV_XARR(ICASE)
         STATS_Y(ICASE) = CSV_YARR(ICASE)
         STATS_ASTOP(ICASE) = CSV_ASTOP(ICASE)
         STATS_TSTOP(ICASE) = CSV_TSTOP(ICASE)
      ENDDO
      DEALLOCATE (CSV_IBANDARR, CSV_XARR, CSV_YARR, CSV_ASTOP, CSV_TSTOP)
   ELSE
      CALL DETERMINE_IGNITION_LOCATIONS
   ENDIF
ENDIF
IF (IRANK_WORLD .EQ. 0 .AND. (.NOT. RANDOM_IGNITIONS) ) STATS_IWX_BAND_START(:) = IWX_BAND_START

CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)
CALL ACCUMULATE_CPU_USAGE(10, IT1, IT2)

IF (IRANK_WORLD .EQ. 0 .AND. CALCULATE_TIMES_BURNED) THEN
   ALLOCATE(BINARY_OUTPUTS_IX(1:ASP%NCOLS*ASP%NROWS))
   ALLOCATE(BINARY_OUTPUTS_IY(1:ASP%NCOLS*ASP%NROWS))

   IF (CALCULATE_FLAME_LENGTH_STATS) ALLOCATE(BINARY_OUTPUTS_FLAME_LENGTH(1:ASP%NCOLS*ASP%NROWS))
   R=>ASP
   CALL ALLOCATE_EMPTY_RASTER(TIMES_BURNED, R%NCOLS, R%NROWS, 1, R%XLLCORNER, R%YLLCORNER, R%CELLSIZE, 0., 'FLOAT     ')
   IF (DUMP_HOURLY_RASTERS) THEN
      CALL ALLOCATE_EMPTY_RASTER(TIMES_BURNED_HOURLY, R%NCOLS, R%NROWS, NUM_STARTING_WX_BANDS, R%XLLCORNER, R%YLLCORNER, R%CELLSIZE, 0., 'FLOAT     ')
   ENDIF
   IF (CALCULATE_FLAME_LENGTH_STATS) THEN
      CALL ALLOCATE_EMPTY_RASTER(FLAME_LENGTH_SUM, R%NCOLS, R%NROWS, 1, R%XLLCORNER, R%YLLCORNER, R%CELLSIZE, 0., 'FLOAT     ')
      CALL ALLOCATE_EMPTY_RASTER(FLAME_LENGTH_MAX, R%NCOLS, R%NROWS, 1, R%XLLCORNER, R%YLLCORNER, R%CELLSIZE, 0., 'FLOAT     ')
      IF (USE_FLAME_LENGTH_BINS) THEN
         CALL ALLOCATE_EMPTY_RASTER(FLAME_LENGTH_BIN_COUNT, R%NCOLS, R%NROWS, NUM_FLAME_LENGTH_BINS, R%XLLCORNER, R%YLLCORNER, R%CELLSIZE, 0., 'SIGNEDINT ')
         FLAME_LENGTH_BIN_COUNT%I2(:,:,:) = 0
      ENDIF
   ENDIF
   IF (USE_EMBER_COUNT_BINS) THEN
      CALL ALLOCATE_EMPTY_RASTER(EMBER_BIN_COUNT, R%NCOLS, R%NROWS, NUM_EMBER_COUNT_BINS, R%XLLCORNER, R%YLLCORNER, R%CELLSIZE, 0., 'SIGNEDINT ')
      EMBER_BIN_COUNT%I2(:,:,:) = 0
   ENDIF
ENDIF

CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)
CALL ACCUMULATE_CPU_USAGE(11, IT1, IT2)

IF (MODE .NE. 1) THEN

   CALL SYSTEM_CLOCK(IT1)

   R=>ASP
   CALL ALLOCATE_EMPTY_RASTER(FLAME_LENGTH_TO_DUMP, R%NCOLS, R%NROWS, 1, R%XLLCORNER, R%YLLCORNER, R%CELLSIZE, R%NODATA_VALUE, 'FLOAT     ')
   CALL ALLOCATE_EMPTY_RASTER(SPREAD_RATE_TO_DUMP , R%NCOLS, R%NROWS, 1, R%XLLCORNER, R%YLLCORNER, R%CELLSIZE, R%NODATA_VALUE, 'FLOAT     ')
   CALL ALLOCATE_EMPTY_RASTER(CROWN_FIRE_TO_DUMP  , R%NCOLS, R%NROWS, 1, R%XLLCORNER, R%YLLCORNER, R%CELLSIZE, R%NODATA_VALUE, 'FLOAT     ')
   FLAME_LENGTH_TO_DUMP%R4(:,:,:) = FLAME_LENGTH_TO_DUMP%NODATA_VALUE
   SPREAD_RATE_TO_DUMP%R4(:,:,:)  = SPREAD_RATE_TO_DUMP%NODATA_VALUE
   CROWN_FIRE_TO_DUMP%R4(:,:,:)  = CROWN_FIRE_TO_DUMP%NODATA_VALUE

   LIST_FIRE_POTENTIAL = NEW_DLL()

   DO IY = 1, ANALYSIS_NROWS
      IF (REAL(IY                    ) * R%CELLSIZE .LT. EDGEBUFFER) CYCLE
      IF (REAL(ANALYSIS_NROWS+1 - IY ) * R%CELLSIZE .LT. EDGEBUFFER) CYCLE
      DO IX = 1, ANALYSIS_NCOLS
         IF (REAL(IX                    ) * R%CELLSIZE .LT. EDGEBUFFER) CYCLE
         IF (REAL(ANALYSIS_NCOLS+1 - IX ) * R%CELLSIZE .LT. EDGEBUFFER) CYCLE
         IF (ISNONBURNABLE(IX,IY) ) CYCLE
         CALL APPEND(LIST_FIRE_POTENTIAL, IX, IY, 0.)
      ENDDO
   ENDDO

   I = -1
   DO IWX_BAND = METEOROLOGY_BAND_START, METEOROLOGY_BAND_STOP
      I = I + 1
      IF (I .EQ. NPROC) I = 0
      IRANK_TO_RUN_METEOROLOGY_BAND(IWX_BAND) = I
   ENDDO

   DO IWX_BAND = METEOROLOGY_BAND_START, METEOROLOGY_BAND_STOP
      IF (IRANK_WORLD .NE. IRANK_TO_RUN_METEOROLOGY_BAND(IWX_BAND)) CYCLE

      WRITE(THREE_IWX_BAND, '(I3.3)') IWX_BAND
      WRITE(*,*) 'IWX_BAND: ', IWX_BAND

      C => LIST_FIRE_POTENTIAL%HEAD
      DO I = 1, LIST_FIRE_POTENTIAL%NUM_NODES
         IX               = C%IX
         IY               = C%IY
         ICOL             = ICOL_ANALYSIS_F2C(IX)
         IROW             = IROW_ANALYSIS_F2C(IY)
         C%M1             = M1%R4   (ICOL,IROW,IWX_BAND)
         C%M10            = M10%R4  (ICOL,IROW,IWX_BAND)
         C%M100           = M100%R4 (ICOL,IROW,IWX_BAND)
         C%MLH            = MLH%R4  (ICOL,IROW,IWX_BAND)
         C%MLW            = MLW%R4  (ICOL,IROW,IWX_BAND)
         C%FMC            = MFOL%R4 (ICOL,IROW,IWX_BAND)
         C%WS20_NOW       = WS%R4   (ICOL,IROW,IWX_BAND)
         C%WD20_NOW       = WD%R4   (ICOL,IROW,IWX_BAND)
         C%WSMF           = C%WS20_NOW * WAF%R4(IX,IY,1) * 5280./60.
         C%PHIW_CROWN     = 0.
         C%FLIN_SURFACE   = 0.
         C%FLIN_CANOPY    = 0.
         C%CRITICAL_FLIN  = 9E9
         C%CROWN_FIRE     = 0
         C => C%NEXT
      ENDDO

      DO J = 1, 2
         IF (J .EQ. 1) CALL SURFACE_SPREAD_RATE(LIST_FIRE_POTENTIAL, DUMMY_NODE)
         IF (J .EQ. 2 .AND. CROWN_FIRE_MODEL .GT. 0) CALL CROWN_SPREAD_RATE  (LIST_FIRE_POTENTIAL, DUMMY_NODE)

         C => LIST_FIRE_POTENTIAL%HEAD
         DO I = 1, LIST_FIRE_POTENTIAL%NUM_NODES
            IX = C%IX
            IY = C%IY

            IF ( J .EQ. 1) THEN 
               IASP = MIN(MAX(NINT(ASP%R4(C%IX,C%IY,1)),0),360)
               SINASPMPI = SINASPM180(IASP)
               COSASPMPI = COSASPM180(IASP) 
               C%PHISX   = C%PHIS_SURFACE * SINASPMPI
               C%PHISY   = C%PHIS_SURFACE * COSASPMPI
            ENDIF

            APHIW = C%PHIW_SURFACE

            IF (J .EQ. 2. .AND. C%FLIN_SURFACE .GE. C%CRITICAL_FLIN) THEN
               APHIW = MAX(C%PHIW_SURFACE, C%PHIW_CROWN)
            ENDIF

            IWD20_TIMES10 = INT(10. * C%WD20_NOW)
            IF (IWD20_TIMES10 .GT. 3600) IWD20_TIMES10 = 3600
            IF (IWD20_TIMES10 .LT.    0) IWD20_TIMES10 =    0

            PHIWX = APHIW * SINWDMPI(IWD20_TIMES10)

            PHIX  = C%PHISX + PHIWX

            PHIWY = APHIW * COSWDMPI(IWD20_TIMES10)
            PHIY  = C%PHISY + PHIWY

            PHIMAG = MAX(SQRT(PHIX*PHIX+PHIY*PHIY),1E-20)

            C%VELOCITY_DMS = C%VS0 * PHIMAG

            C%FLIN_SURFACE = TR(C%IFBFM) * C%IR * C%VELOCITY_DMS * 0.3048 ! kW/m
            IF (J .EQ. 2) THEN
               SPREAD_RATE_TO_DUMP%R4(IX,IY,1) = C%VELOCITY_DMS

               CROWN_FIRE_TO_DUMP%R4(IX,IY,1) = REAL(C%CROWN_FIRE)
 
               IF (C%FLIN_SURFACE .GT. 0.) THEN
                  C%FLAME_LENGTH = (0.0775 / 0.3048) * (C%FLIN_SURFACE + C%FLIN_CANOPY) ** 0.46
               ELSE
                  C%FLAME_LENGTH = 0.
               ENDIF
               FLAME_LENGTH_TO_DUMP%R4(IX,IY,1) = C%FLAME_LENGTH
            ENDIF
            C => C%NEXT

         ENDDO !I
      ENDDO !J

      IF (DUMP_FLAME_LENGTH) THEN
         FN = 'head_fire_flame_length_' // THREE_IWX_BAND
         CALL WRITE_BIL_RASTER(FLAME_LENGTH_TO_DUMP,OUTPUTS_DIRECTORY,FN,CONVERT_TO_GEOTIFF,.TRUE.,IWX_BAND)
      ENDIF

      IF (DUMP_SPREAD_RATE) THEN
         FN = 'head_fire_spread_rate_' // THREE_IWX_BAND
         CALL WRITE_BIL_RASTER(SPREAD_RATE_TO_DUMP,OUTPUTS_DIRECTORY,FN,CONVERT_TO_GEOTIFF,.TRUE.,IWX_BAND)
      ENDIF

      IF (DUMP_CROWN_FIRE) THEN
         FN = 'crown_fire_' // THREE_IWX_BAND
         CALL WRITE_BIL_RASTER(CROWN_FIRE_TO_DUMP,OUTPUTS_DIRECTORY,FN,CONVERT_TO_GEOTIFF,.TRUE.,IWX_BAND)
      ENDIF

   ENDDO !IWX_BAND

ENDIF ! (MODE .GT. 1)

CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)

IF (MULTIPLE_HOSTS) THEN
   CALL MPI_BCAST(STATS_X                         , NUM_CASES_TOTAL, MPI_REAL   , 0, MPI_COMM_HOST_IRANK0, IERR)
   CALL MPI_BCAST(STATS_Y                         , NUM_CASES_TOTAL, MPI_REAL   , 0, MPI_COMM_HOST_IRANK0, IERR)
   CALL MPI_BCAST(STATS_ASTOP                     , NUM_CASES_TOTAL, MPI_REAL   , 0, MPI_COMM_HOST_IRANK0, IERR)   
   CALL MPI_BCAST(STATS_TSTOP                     , NUM_CASES_TOTAL, MPI_REAL   , 0, MPI_COMM_HOST_IRANK0, IERR)   
   CALL MPI_BCAST(STATS_SURFACE_FIRE_AREA         , NUM_CASES_TOTAL, MPI_REAL   , 0, MPI_COMM_HOST_IRANK0, IERR)
   CALL MPI_BCAST(STATS_CROWN_FIRE_AREA           , NUM_CASES_TOTAL, MPI_REAL   , 0, MPI_COMM_HOST_IRANK0, IERR)
   CALL MPI_BCAST(STATS_FIRE_VOLUME               , NUM_CASES_TOTAL, MPI_REAL   , 0, MPI_COMM_HOST_IRANK0, IERR)
   CALL MPI_BCAST(STATS_AFFECTED_POPULATION       , NUM_CASES_TOTAL, MPI_REAL   , 0, MPI_COMM_HOST_IRANK0, IERR)
   CALL MPI_BCAST(STATS_AFFECTED_REAL_ESTATE_VALUE, NUM_CASES_TOTAL, MPI_REAL   , 0, MPI_COMM_HOST_IRANK0, IERR)
   CALL MPI_BCAST(STATS_AFFECTED_LAND_VALUE       , NUM_CASES_TOTAL, MPI_REAL   , 0, MPI_COMM_HOST_IRANK0, IERR)
   CALL MPI_BCAST(STATS_FINAL_CONTAINMENT_FRAC    , NUM_CASES_TOTAL, MPI_REAL   , 0, MPI_COMM_HOST_IRANK0, IERR)
   CALL MPI_BCAST(STATS_NEMBERS                   , NUM_CASES_TOTAL, MPI_REAL   , 0, MPI_COMM_HOST_IRANK0, IERR)
   CALL MPI_BCAST(STATS_IWX_BAND_START            , NUM_CASES_TOTAL, MPI_INTEGER, 0, MPI_COMM_HOST_IRANK0, IERR)
   CALL MPI_BCAST(STATS_IWX_SERIAL_BAND           , NUM_CASES_TOTAL, MPI_INTEGER, 0, MPI_COMM_HOST_IRANK0, IERR)
   CALL MPI_BCAST(STATS_SIMULATION_TSTOP_HOURS    , NUM_CASES_TOTAL, MPI_REAL   , 0, MPI_COMM_HOST_IRANK0, IERR)
   CALL MPI_BCAST(STATS_WALL_CLOCK_TIME           , NUM_CASES_TOTAL, MPI_REAL   , 0, MPI_COMM_HOST_IRANK0, IERR)
   CALL MPI_BCAST(STATS_PM2P5_RELEASE             , NUM_CASES_TOTAL, MPI_REAL   , 0, MPI_COMM_HOST_IRANK0, IERR)
   CALL MPI_BCAST(STATS_HRR_PEAK                  , NUM_CASES_TOTAL, MPI_REAL   , 0, MPI_COMM_HOST_IRANK0, IERR)
ENDIF

IF (MODE .NE. 2) THEN

   IF (IRANK_WORLD .EQ. 0) THEN
      MESSAGESTR='ELMFIRE is running each ensemble member'
      WRITE(*,*) TRIM(MESSAGESTR)
   ENDIF

   ICASE = 0
   DO WHILE (ICASE .LT. NUM_CASES_TOTAL)

      CALL SYSTEM_CLOCK(IT1)

      IF (IRANK_WORLD .EQ. 0 .AND. NPROC .GT. 1) ICASE = NUM_CASES_TOTAL + 1 !This, with the next line, kicks IRANK_WORLD = 0 out of this loop
      IF (ICASE .GT. NUM_CASES_TOTAL) CYCLE

      IF (NPROC .GT. 1) THEN
         CALL MPI_RECV(ICASE, 1, MPI_INTEGER, 0, 1234, MPI_COMM_WORLD, ISTATUS)
      ELSE
         ICASE = ICASE + 1
      ENDIF

      CALL ACCUMULATE_CPU_USAGE(12, IT1, IT2)

      IF (ICASE .GT. NUM_CASES_TOTAL) CYCLE

      IWX_BAND = STATS_IWX_BAND_START(ICASE)

      IF (IWX_BAND .NE. IWX_BAND_LAST) THEN            
         WSP  (1:,1:,1:) => WS%R4  (1:,1:,IWX_BAND:)
         WDP  (1:,1:,1:) => WD%R4  (1:,1:,IWX_BAND:)
         M1P  (1:,1:,1:) => M1%R4  (1:,1:,IWX_BAND:)
         M10P (1:,1:,1:) => M10%R4 (1:,1:,IWX_BAND:)
         M100P(1:,1:,1:) => M100%R4(1:,1:,IWX_BAND:)
         MLHP (1:,1:,1:) => MLH%R4 (1:,1:,IWX_BAND:)
         MLWP (1:,1:,1:) => MLW%R4 (1:,1:,IWX_BAND:)
         MFOLP(1:,1:,1:) => MFOL%R4(1:,1:,IWX_BAND:)
         IF (USE_ERC) THEN
            ERCP   (1:,1:,1:) => ERC%R4   (1:,1:,IWX_BAND:)
            IGNFACP(1:,1:,1:) => IGNFAC%R4(1:,1:,IWX_BAND:)
         ENDIF
      ENDIF
      
      CALL ACCUMULATE_CPU_USAGE(13, IT1, IT2)
   
      IF (NUM_MONTE_CARLO_VARIABLES .GT. 0 ) CALL RANDOM_NUMBER(COEFFS(:))

      IF (NUM_RASTERS_TO_PERTURB .GT. 0) CALL PERTURB_RASTERS(COEFFS(:))

      CALL ACCUMULATE_CPU_USAGE(14, IT1, IT2)
      
      IF (ENABLE_SPOTTING) CALL SET_SPOTTING_PARAMETERS(COEFFS(:))

      IF (NUM_PARAMETERS_MISC .GT. 0) CALL SET_MISC_PARAMETERS(COEFFS(:))

      CALL ACCUMULATE_CPU_USAGE(15, IT1, IT2)
     
! Main call to spread model
      IT1_LSP = IT1
      CALL LEVEL_SET_PROPAGATION(IWX_BAND,ICASE,NTIMESTEPS)
      WRITE(*,'(A, I6, A, I7, A, F8.1, A)') "Meteorology band ", IWX_BAND, ": Case # ", ICASE, " complete.  Fire area: ", &
                                             STATS_SURFACE_FIRE_AREA(ICASE), " acres."
      CALL SYSTEM_CLOCK(IT2)
      STATS_WALL_CLOCK_TIME(ICASE) = REAL(IT2 - IT1) / REAL(CLOCK_COUNT_RATE)
      TIMINGS(IRANK_HOST+1,80) = TIMINGS(IRANK_HOST+1,80) + STATS_WALL_CLOCK_TIME(ICASE)
      CALL SYSTEM_CLOCK(IT1)

      IF (NPROC .GT. 1) THEN
         CALL MPI_SEND(IRANK_WORLD, 1, MPI_INTEGER, 0, 210, MPI_COMM_WORLD, IERR) ! This tells IRANK_WORLD0 which rank just finished
         CALL MPI_SEND(ICASE, 1, MPI_INTEGER, 0, 211, MPI_COMM_WORLD, IERR)
         IF (NUM_MONTE_CARLO_VARIABLES .GT. 0) THEN
            CALL MPI_SEND(COEFFS_UNSCALED(:), NUM_MONTE_CARLO_VARIABLES, MPI_REAL, 0, 226, MPI_COMM_WORLD, IERR)
         ENDIF

         IF (CALCULATE_TIMES_BURNED) THEN
            N = LIST_BURNED%NUM_NODES_PREVIOUS
            CALL MPI_SEND(N                     , 1, MPI_INTEGER, 0, 212, MPI_COMM_WORLD, IERR)
            CALL MPI_SEND(BINARY_OUTPUTS_IX(1:N), N, MPI_SHORT  , 0, 213, MPI_COMM_WORLD, IERR)
            CALL MPI_SEND(BINARY_OUTPUTS_IY(1:N), N, MPI_SHORT  , 0, 214, MPI_COMM_WORLD, IERR)
            IF (CALCULATE_FLAME_LENGTH_STATS) CALL MPI_SEND(BINARY_OUTPUTS_FLAME_LENGTH(1:N), N, MPI_REAL  , 0, 215, MPI_COMM_WORLD, IERR)
         ENDIF

         IF (USE_EMBER_COUNT_BINS) THEN
            N = INT(STATS_NEMBERS(ICASE))
            CALL MPI_SEND(N                       , 1, MPI_INTEGER, 0, 222, MPI_COMM_WORLD, IERR)
            CALL MPI_SEND(EMBER_OUTPUTS_IX   (1:N), N, MPI_SHORT  , 0, 223, MPI_COMM_WORLD, IERR)
            CALL MPI_SEND(EMBER_OUTPUTS_IY   (1:N), N, MPI_SHORT  , 0, 224, MPI_COMM_WORLD, IERR)
            CALL MPI_SEND(EMBER_OUTPUTS_COUNT(1:N), N, MPI_SHORT  , 0, 225, MPI_COMM_WORLD, IERR)
         ENDIF

      ENDIF

      IWX_BAND_LAST = IWX_BAND

      CALL ACCUMULATE_CPU_USAGE(16, IT1, IT2)

   ENDDO

! This part gets run by the master process so it can dole out jobs to the slave processes:
   IF (IRANK_WORLD .EQ. 0 .AND. NPROC .GT. 1) THEN

      TOTALCASESRUN = 0

! Start by distributing case to run to all slave nodes
      ICASE = 0
      DO IDEST = 1, NPROC - 1
         ICASE = ICASE + 1
         CALL MPI_SEND(ICASE, 1, MPI_INTEGER, IDEST, 1234, MPI_COMM_WORLD, IERR)
      ENDDO

      DO WHILE (TOTALCASESRUN .LT. NUM_CASES_TOTAL)

         CALL SYSTEM_CLOCK(IT1)

         CALL MPI_RECV(IRANK_FROM, 1, MPI_INTEGER, MPI_ANY_SOURCE, 210, MPI_COMM_WORLD, ISTATUS)

         CALL ACCUMULATE_CPU_USAGE(17, IT1, IT2)

         CALL MPI_RECV(ICASE_RECV, 1, MPI_INTEGER, IRANK_FROM, 211, MPI_COMM_WORLD, ISTATUS)
         IF (NUM_MONTE_CARLO_VARIABLES .GT. 0) THEN
            CALL MPI_RECV(COEFFS_UNSCALED, NUM_MONTE_CARLO_VARIABLES, MPI_REAL, IRANK_FROM, 226, MPI_COMM_WORLD, ISTATUS)
            COEFFS_UNSCALED_BY_CASE(ICASE_RECV,:) = COEFFS_UNSCALED(:)
         ENDIF

         IF (CALCULATE_TIMES_BURNED) THEN
            CALL MPI_RECV(N                     , 1, MPI_INTEGER, IRANK_FROM, 212, MPI_COMM_WORLD, ISTATUS)
            CALL MPI_RECV(BINARY_OUTPUTS_IX(1:N), N, MPI_SHORT  , IRANK_FROM, 213, MPI_COMM_WORLD, ISTATUS)
            CALL MPI_RECV(BINARY_OUTPUTS_IY(1:N), N, MPI_SHORT  , IRANK_FROM, 214, MPI_COMM_WORLD, ISTATUS)

            IF (CALCULATE_FLAME_LENGTH_STATS) CALL MPI_RECV(BINARY_OUTPUTS_FLAME_LENGTH(1:N), N, MPI_REAL  , IRANK_FROM, 215, MPI_COMM_WORLD, ISTATUS)

            IF (DUMP_HOURLY_RASTERS) THEN
               DO I = 1, N
                  IX = BINARY_OUTPUTS_IX(I)
                  IY = BINARY_OUTPUTS_IY(I)
                  IBAND = STATS_IWX_SERIAL_BAND(ICASE_RECV)
                  TIMES_BURNED%R4(IX,IY,1) = TIMES_BURNED%R4(IX,IY,1) + 1.
                  TIMES_BURNED_HOURLY%R4(IX,IY,IBAND) = TIMES_BURNED_HOURLY%R4(IX,IY,IBAND) + 1.
               ENDDO
            ELSE
               DO I = 1, N
                  IX = BINARY_OUTPUTS_IX(I)
                  IY = BINARY_OUTPUTS_IY(I)
                  TIMES_BURNED%R4(IX,IY,1) = TIMES_BURNED%R4(IX,IY,1) + 1.
               ENDDO
            ENDIF

            IF (CALCULATE_FLAME_LENGTH_STATS) THEN
               DO I = 1, N
                  IX = BINARY_OUTPUTS_IX(I)
                  IY = BINARY_OUTPUTS_IY(I)
                  FLAME_LENGTH_SUM%R4(IX,IY,1) = FLAME_LENGTH_SUM%R4(IX,IY,1) + BINARY_OUTPUTS_FLAME_LENGTH(I)
                  IF (BINARY_OUTPUTS_FLAME_LENGTH(I) .GT. FLAME_LENGTH_MAX%R4(IX,IY,1) ) THEN
                     FLAME_LENGTH_MAX%R4(IX,IY,1) = BINARY_OUTPUTS_FLAME_LENGTH(I)
                  ENDIF
               ENDDO

               IF (USE_FLAME_LENGTH_BINS) THEN
                  DO I = 1, N
                     IX = BINARY_OUTPUTS_IX(I)
                     IY = BINARY_OUTPUTS_IY(I)
                     DO IBIN = 1, NUM_FLAME_LENGTH_BINS
                        IF (BINARY_OUTPUTS_FLAME_LENGTH(I) .GE. FLAME_LENGTH_BIN_LO(IBIN) ) THEN
                           IF (BINARY_OUTPUTS_FLAME_LENGTH(I) .LT. FLAME_LENGTH_BIN_HI(IBIN) ) THEN
                              FLAME_LENGTH_BIN_COUNT%I2(IX,IY,IBIN) = FLAME_LENGTH_BIN_COUNT%I2(IX,IY,IBIN) + 1
                           ENDIF
                        ENDIF
                     ENDDO
                  ENDDO
               ENDIF
            ENDIF

         ENDIF

         IF (USE_EMBER_COUNT_BINS) THEN
            IF (ALLOCATED(EMBER_OUTPUTS_IX)) THEN
               DEALLOCATE (EMBER_OUTPUTS_IX)
               DEALLOCATE (EMBER_OUTPUTS_IY)
               DEALLOCATE (EMBER_OUTPUTS_COUNT)
            ENDIF

            CALL MPI_RECV(N, 1, MPI_INTEGER, IRANK_FROM, 222, MPI_COMM_WORLD, ISTATUS)

            ALLOCATE(EMBER_OUTPUTS_IX   (1:N))
            ALLOCATE(EMBER_OUTPUTS_IY   (1:N))
            ALLOCATE(EMBER_OUTPUTS_COUNT(1:N))

            CALL MPI_RECV(EMBER_OUTPUTS_IX   (1:N), N, MPI_SHORT, IRANK_FROM, 223, MPI_COMM_WORLD, ISTATUS)
            CALL MPI_RECV(EMBER_OUTPUTS_IY   (1:N), N, MPI_SHORT, IRANK_FROM, 224, MPI_COMM_WORLD, ISTATUS)
            CALL MPI_RECV(EMBER_OUTPUTS_COUNT(1:N), N, MPI_SHORT, IRANK_FROM, 225, MPI_COMM_WORLD, ISTATUS)

            DO I = 1, N
               IF (EMBER_OUTPUTS_COUNT(I) .GT. 0) THEN
                  IX = EMBER_OUTPUTS_IX(I)
                  IY = EMBER_OUTPUTS_IY(I)
                  DO IBIN = 1, NUM_EMBER_COUNT_BINS
                     IF (EMBER_OUTPUTS_COUNT(I) .GT. EMBER_COUNT_BIN_LO(IBIN) ) THEN
                        IF (EMBER_OUTPUTS_COUNT(I) .LE. EMBER_COUNT_BIN_HI(IBIN) ) THEN
                           EMBER_BIN_COUNT%I2(IX,IY,IBIN) = EMBER_BIN_COUNT%I2(IX,IY,IBIN) + 1
                           CYCLE
                        ENDIF
                     ENDIF
                  ENDDO
               ENDIF
            ENDDO

         ENDIF

         CALL ACCUMULATE_CPU_USAGE(18, IT1, IT2)

         TOTALCASESRUN = TOTALCASESRUN + 1

         IF (TOTALCASESRUN .LT. NUM_CASES_TOTAL) THEN
            ICASE = ICASE + 1
         ELSE
            ICASE = NUM_CASES_TOTAL + 1
         ENDIF
         CALL MPI_SEND(ICASE, 1, MPI_INTEGER, IRANK_FROM, 1234, MPI_COMM_WORLD, IERR)

      CALL ACCUMULATE_CPU_USAGE(19, IT1, IT2)

      ENDDO !TOTALCASESRUN .LT. NUM_CASES_TOTAL
   
   ENDIF ! End part that is run only by IRANK_WORLD = 0

   CALL ACCUMULATE_CPU_USAGE(20, IT1, IT2)

! Once we get here, all simulations are done and we have some post-processing to do

   CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)

   CALL ACCUMULATE_CPU_USAGE(21, IT1, IT2)

   CALL POSTPROCESS()

   CALL ACCUMULATE_CPU_USAGE(22, IT1, IT2)

ENDIF !MODE .NE. 2

CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)

CALL SHUTDOWN()

! *****************************************************************************
END PROGRAM ELMFIRE
! *****************************************************************************

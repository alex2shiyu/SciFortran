subroutine p_Dinv(A,Nblock,blacs_end)
  real(8),dimension(:,:),intent(inout)       :: A
  integer                                    :: Nblock
  integer,optional                           :: blacs_end
  integer                                    :: Nb
  integer                                    :: blacs_end_
  integer                                    :: Ns
  integer                                    :: Qrows,Qcols
  integer                                    :: i,j,lda,info
  !
  real(8)                                    :: guess_lwork(1)
  integer                                    :: guess_liwork(1)
  real(8),dimension(:),allocatable           :: work
  integer,dimension(:),allocatable           :: Iwork 
  integer                                    :: lwork
  integer                                    :: liwork
  integer, allocatable                       :: ipiv(:)
  !
  integer,external                           :: numroc,indxG2L,indxG2P,indxL2G
  real(8),external                           :: dlamch,Pilaenvx
  !
  real(8),dimension(:,:),allocatable         :: A_loc
  integer                                    :: p_size
  integer                                    :: p_Nx,p_Ny
  integer                                    :: p_context
  integer                                    :: rank,rankX,rankY
  integer                                    :: sendR,sendC,Nipiv
  integer                                    :: Nrow,Ncol
  integer                                    :: myi,myj,unit,irank
  integer,dimension(9)                       :: descA,descAloc,descZloc
  real(8)                                    :: t_stop,t_start
  logical                                    :: master
  !
  blacs_end_=0   ;if(present(blacs_end))blacs_end_=blacs_end
  !
  !
  Ns    = max(1,size(A,1))
  if(any(shape(A)/=[Ns,Ns]))stop "my_eighD error: A has illegal shape"
  !
  !INIT SCALAPACK TREATMENT:
  !
  !< Initialize BLACS processor grid (like MPI)
  call blacs_setup(rank,p_size)  ![id, size]
  master = (rank==0)
  do i=1,int( sqrt( dble(p_size) ) + 1 )
     if(mod(p_size,i)==0) p_Nx = i
  end do
  p_Ny = p_size/p_Nx
  !
  !< Init context with p_Nx,p_Ny procs
  call sl_init(p_context,p_Nx,p_Ny)
  !
  !< Get coordinate of the processes
  call blacs_gridinfo( p_context, p_Nx, p_Ny, rankX, rankY)
  !
  if(rankX<0.AND.rankY<0)goto 100
  !
  Nb = Nblock
  !
  Qrows = numroc(Ns, Nb, rankX, 0, p_Nx)
  Qcols = numroc(Ns, Nb, rankY, 0, p_Ny)
  !
  if(master)then
     unit = 519
     open(unit,file="p_inv.info")
     write(unit,"(A20,I8,A5,I8)")"Grid=",p_Nx,"x",p_Ny
     write(unit,"(A20,I2,I8,A5,I8)")"Qrows x Qcols=",rank,Qrows,"x",Qcols
  endif
  !
  !< allocate local distributed A
  allocate(A_loc(Qrows,Qcols))
  call descinit( descA, Ns, Ns, Nb, Nb, 0, 0, p_context, Qrows, info )
  call descinit( descAloc, Ns, Ns, Nb, Nb, 0, 0, p_context, Qrows, info )
  !
  !< Distribute A
  if(master)call cpu_time(t_start)
  do myi=1,Qrows
     i  = indxL2G(myi,Nblock,rankX,0,p_Nx)
     do myj=1,Qcols
        j  = indxL2G(myj,Nblock,rankY,0,p_Ny)
        A_loc(myi,myj) = A(i,j)
     enddo
  enddo
  if(master)call cpu_time(t_stop)
  if(master)write(unit,"(A20,F21.12)")"Time Distribute A:",t_stop-t_start
  !
  if(master)call cpu_time(t_start)
  allocate(Ipiv(Qrows*Nb))
  call PDGETRF(Ns, Ns, A_loc, 1, 1, descAloc, IPIV, INFO)
  if(info /= 0) then
     print*, "PDGETRF returned info =", info
     if (info < 0) then
        print*, "the", -info, "-th argument had an illegal value"
     else
        print*, "U(", info, ",", info, ") is zero; The factorization"
        print*, "Factorization completed, but U is singular"
     end if
     stop ' Pdgetrf error'
  end if
  !
  !
  call PDGETRI( Ns, A_loc, 1, 1, descAloc, IPIV, guess_lWORK, -1, guess_LIWORK, -1, INFO )
  lwork = guess_lwork(1)
  liwork= guess_liwork(1)
  allocate(work(lwork))
  allocate(iwork(liwork))
  call PDGETRI( Ns, A_loc, 1, 1, descAloc, IPIV, Work, Lwork, Iwork, LIwork, INFO )
  if(info /= 0) then
     print*, "PDGETRI ERROR. returned info =", info
     stop
  end if
  !
  if(master)call cpu_time(t_stop)
  if(master)write(unit,"(A20,F21.12)")"Time inv A_loc:",t_stop-t_start
  !
  A=0d0
  if(master)call cpu_time(t_start)
  do i=1,Ns,Nb
     Nrow = Nb ; if(Ns-i<Nb-1)Nrow=Ns-i+1!;if(Nrow==0)Nrow=1
     do j=1,Ns,Nb
        Ncol = Nb ; if(Ns-j<Nb-1)Ncol=Ns-j+1!;if(Ncol==0)Ncol=1
        call infog2l(i,j,descA, p_Nx, p_Ny, rankX, rankY, myi, myj, SendR, SendC)
        if(rankX==SendR .AND. rankY==SendC)then
           call dgesd2d(p_context,Nrow,Ncol,A_loc(myi,myj),Qrows,0,0)
        endif
        if(rank==0)then
           call dgerv2d(p_context,Nrow,Ncol,A(i,j),Ns,SendR,SendC)
        endif
     enddo
  enddo
  if(master)call cpu_time(t_stop)
  if(master)write(unit,"(A20,F21.12)")"Time gather A:",t_stop-t_start
  !
  if(master)close(unit)
  call blacs_gridexit(p_context)
100 continue
  call blacs_exit(blacs_end_)
  return
  !
end subroutine p_Dinv



subroutine p_Zinv(A,Nblock,blacs_end)
  complex(8),dimension(:,:),intent(inout) :: A
  integer                                 :: Nblock
  integer,optional                        :: blacs_end
  integer                                 :: Nb
  integer                                 :: blacs_end_
  integer                                 :: Ns
  integer                                 :: Qrows,Qcols
  integer                                 :: i,j,lda,info
  !
  complex(8)                              :: guess_lwork(1)
  integer                                 :: guess_liwork(1)
  complex(8),dimension(:),allocatable     :: work
  integer,dimension(:),allocatable        :: Iwork 
  integer                                 :: lwork
  integer                                 :: liwork
  integer, allocatable                    :: ipiv(:)
  !
  integer,external                        :: numroc,indxG2L,indxG2P,indxL2G
  !
  complex(8),dimension(:,:),allocatable   :: A_loc
  integer                                 :: p_size
  integer                                 :: p_Nx,p_Ny
  integer                                 :: p_context
  integer                                 :: rank,rankX,rankY
  integer                                 :: sendR,sendC,Nipiv
  integer                                 :: Nrow,Ncol
  integer                                 :: myi,myj,unit,irank
  integer,dimension(9)                    :: descA,descAloc,descZloc
  real(8)                                 :: t_stop,t_start
  logical                                 :: master
  !
  blacs_end_=0   ;if(present(blacs_end))blacs_end_=blacs_end
  !
  !
  Ns    = max(1,size(A,1))
  if(any(shape(A)/=[Ns,Ns]))stop "my_eighD error: A has illegal shape"
  !
  !INIT SCALAPACK TREATMENT:
  !
  !< Initialize BLACS processor grid (like MPI)
  call blacs_setup(rank,p_size)  ![id, size]
  master = (rank==0)
  do i=1,int( sqrt( dble(p_size) ) + 1 )
     if(mod(p_size,i)==0) p_Nx = i
  end do
  p_Ny = p_size/p_Nx
  !
  !< Init context with p_Nx,p_Ny procs
  call sl_init(p_context,p_Nx,p_Ny)
  !
  !< Get coordinate of the processes
  call blacs_gridinfo( p_context, p_Nx, p_Ny, rankX, rankY)
  !
  if(rankX<0.AND.rankY<0)goto 200
  !
  Nb = Nblock
  !
  Qrows = numroc(Ns, Nb, rankX, 0, p_Nx)
  Qcols = numroc(Ns, Nb, rankY, 0, p_Ny)
  !
  if(master)then
     unit = 519
     open(unit,file="p_inv.info")
     write(unit,"(A20,I8,A5,I8)")"Grid=",p_Nx,"x",p_Ny
     write(unit,"(A20,I2,I8,A5,I8)")"Qrows x Qcols=",rank,Qrows,"x",Qcols
  endif
  !
  !< allocate local distributed A
  allocate(A_loc(Qrows,Qcols))
  call descinit( descA, Ns, Ns, Nb, Nb, 0, 0, p_context, Qrows, info )
  call descinit( descAloc, Ns, Ns, Nb, Nb, 0, 0, p_context, Qrows, info )
  !
  !< Distribute A
  if(master)call cpu_time(t_start)
  do myi=1,Qrows
     i  = indxL2G(myi,Nblock,rankX,0,p_Nx)
     do myj=1,Qcols
        j  = indxL2G(myj,Nblock,rankY,0,p_Ny)
        A_loc(myi,myj) = A(i,j)
     enddo
  enddo
  if(master)call cpu_time(t_stop)
  if(master)write(unit,"(A20,F21.12)")"Time Distribute A:",t_stop-t_start
  !
  !< Allocate distributed eigenvector matrix
  if(master)call cpu_time(t_start)
  allocate(Ipiv(Qrows*Nb))
  call PZGETRF(Ns, Ns, A_loc, 1, 1, descAloc, IPIV, INFO)
  if(info /= 0) then
     print*, "PZGETRF returned info =", info
     if (info < 0) then
        print*, "the", -info, "-th argument had an illegal value"
     else
        print*, "U(", info, ",", info, ") is zero; The factorization"
        print*, "Factorization completed, but U is singular"
     end if
     stop
  end if
  !
  !
  call PZGETRI( Ns, A_loc, 1, 1, descAloc, IPIV, guess_lWORK, -1, guess_LIWORK, -1, INFO )
  lwork = guess_lwork(1)
  liwork= guess_liwork(1)
  allocate(work(lwork))
  allocate(iwork(liwork))
  call PZGETRI( Ns, A_loc, 1, 1, descAloc, IPIV, Work, Lwork, Iwork, LIwork, INFO )
  if(info /= 0) then
     print*, "PZGETRI ERROR. returned info =", info
     stop
  end if
  !
  if(master)call cpu_time(t_stop)
  if(master)write(unit,"(A20,F21.12)")"Time inv A_loc:",t_stop-t_start
  !
  A=zero
  if(master)call cpu_time(t_start)
  do i=1,Ns,Nb
     Nrow = Nb ; if(Ns-i<Nb-1)Nrow=Ns-i+1!;if(Nrow==0)Nrow=1
     do j=1,Ns,Nb
        Ncol = Nb ; if(Ns-j<Nb-1)Ncol=Ns-j+1!;if(Ncol==0)Ncol=1
        call infog2l(i,j,descA, p_Nx, p_Ny, rankX, rankY, myi, myj, SendR, SendC)
        if(rankX==SendR .AND. rankY==SendC)then
           call zgesd2d(p_context,Nrow,Ncol,A_loc(myi,myj),Qrows,0,0)
        endif
        if(rank==0)then
           call zgerv2d(p_context,Nrow,Ncol,A(i,j),Ns,SendR,SendC)
        endif
     enddo
  enddo
  if(master)call cpu_time(t_stop)
  if(master)write(unit,"(A20,F21.12)")"Time gather A:",t_stop-t_start
  !
  if(master)close(unit)
  call blacs_gridexit(p_context)
200 continue
  call blacs_exit(blacs_end_)
  return
  !
end subroutine p_Zinv

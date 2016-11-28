set quoted_identifier off;
go
use master
go

create procedure sp_RestoreChainByDB2
	@DBName sysname,
	@Output int = 1, --  default to previous versions output
	@MaxFullBackupDate date = NULL 

as
begin
/****************
Created by @SQLSoldier
http://www.sqlsoldier.com/wp/sqlserver/day3of31daysofdisasterrecoverydeterminingfilestorestoredatabase

2015-09-24
Modified by Anders Pedersen 
Twitter: @arrowdrive
Blog: Blog.AndersOnSQL.com
Made to work with SQL 2008R2.


2016-02-26
Modified by Anders Pedersen
Fix issue where First_LSN and Last_LSN values are the same on a record for the trasaction log backups.
These transaction log backups can be ignored in the restore chain.
Also made into a procedure, with the database name for a required parameter, and max date for the full backup to start with as a parameter

2016-11-28
Modified by Anders Pedersen
Added support for scripting out restore statements.
Added parameter @output for what the script should print out: 1 = Restore chain only, 2 = Restore Script only, 3 = both

Note that the restore scripts assume the files are going back to the original location.  
	This part could easily be modified by adding parameters for data and log file location
	Or even made table driven if a lot of files going to different locations.
	This was made for my own need to quickly create a restore chain to recover a server where the databases existed, but had to be over written.
*****************/
	Declare @DBBackupLSN numeric(25, 0)

	Declare @Baks Table (
		BakID int identity(1, 1) not null primary key,
		backup_set_id int not null,
		media_set_id int not null,
		first_family_number tinyint not null,
		last_family_number tinyint not null,
		first_lsn numeric(25, 0) null,
		last_lsn numeric(25, 0) null,
		database_backup_lsn numeric(25, 0) null,
		backup_finish_date datetime null,
		type char(1) null,
		family_sequence_number tinyint not null,
		physical_device_name nvarchar(260) not null,
		device_type tinyint null,
		checkpoint_LSN numeric (25,0)-- Anders 2015-09-24
		)
	Set NoCount On;



	-- Get the most recent full backup with all backup files
	Insert Into @Baks (backup_set_id,
		media_set_id,
		first_family_number,
		last_family_number,
		first_lsn,
		last_lsn,
		database_backup_lsn,
		backup_finish_date,
		type,
		family_sequence_number,
		physical_device_name,
		device_type
		,checkpoint_LSN)-- Anders
	Select Top(1) With Ties B.backup_set_id,
		B.media_set_id,
		B.first_family_number,
		B.last_family_number,
		B.first_lsn,
		B.last_lsn,
		B.database_backup_lsn,
		B.backup_finish_date,
		B.type,
		BF.family_sequence_number,
		BF.physical_device_name,
		BF.device_type
		, B.checkpoint_lsn -- Anders 2015-09-24
	From msdb.dbo.backupset As B
	Inner Join msdb.dbo.backupmediafamily As BF
		On BF.media_set_id = B.media_set_id
			And BF.family_sequence_number Between B.first_family_number And B.last_family_number
	Where B.database_name = @DBName
	And B.is_copy_only = 0
	And B.type = 'D'
	And BF.physical_device_name Not In ('Nul', 'Nul:')
	and convert(DATE,B.backup_start_date) <=(CASE 
											when @MaxFullBackupDate is not null then   @MaxFullBackupDate 
											else convert(DATE,B.backup_start_date) end) -- Anders 2016-02-26
		
	Order By backup_finish_date desc, backup_set_id;


	-- Get the lsn that the differential backups, if any, will be based on
	Select @DBBackupLSN = checkpoint_LSN -- Anders 2015-09-24
	From @Baks;

	-- Get the most recent differential backup based on that full backup
	Insert Into @Baks (backup_set_id,
		media_set_id,
		first_family_number,
		last_family_number,
		first_lsn,
		last_lsn,
		database_backup_lsn,
		backup_finish_date,
		type,
		family_sequence_number,
		physical_device_name,
		device_type)
	Select Top(1) With Ties B.backup_set_id,
		B.media_set_id,
		B.first_family_number,
		B.last_family_number,
		B.first_lsn,
		B.last_lsn,
		B.database_backup_lsn,
		B.backup_finish_date,
		B.type,
		BF.family_sequence_number,
		BF.physical_device_name,
		BF.device_type
	From msdb.dbo.backupset As B
	Inner Join msdb.dbo.backupmediafamily As BF
		On BF.media_set_id = B.media_set_id
			And BF.family_sequence_number Between B.first_family_number And B.last_family_number
	Where B.database_name = @DBName
	And B.is_copy_only = 0
	And B.type = 'I'
	And BF.physical_device_name Not In ('Nul', 'Nul:')
	And B.database_backup_lsn = @DBBackupLSN 

	Order By backup_finish_date Desc, backup_set_id;


	--select * from @Baks

	-- Get the last LSN included in the differential backup,
	-- if one was found, or of the full backup
	Select Top 1 @DBBackupLSN = last_lsn
	From @Baks
	Where type In ('D', 'I')
	Order By BakID Desc;

	-- Get first log backup, if any, for restore, where
	-- last_lsn of previous backup is >= first_lsn of the
	-- log backup and <= the last_lsn of the log backup
	Insert Into @Baks (backup_set_id,
		media_set_id,
		first_family_number,
		last_family_number,
		first_lsn,
		last_lsn,
		database_backup_lsn,
		backup_finish_date,
		type,
		family_sequence_number,
		physical_device_name,
		device_type)
	Select Top(1) With Ties B.backup_set_id,
		B.media_set_id,
		B.first_family_number,
		B.last_family_number,
		B.first_lsn,
		B.last_lsn,
		B.database_backup_lsn,
		B.backup_finish_date,
		B.type,
		BF.family_sequence_number,
		BF.physical_device_name,
		BF.device_type
	From msdb.dbo.backupset B
	Inner Join msdb.dbo.backupmediafamily As BF
		On BF.media_set_id = B.media_set_id
			And BF.family_sequence_number Between B.first_family_number And B.last_family_number
	Where B.database_name = @DBName
	And B.is_copy_only = 0
	And B.type = 'L'
	And BF.physical_device_name Not In ('Nul', 'Nul:')
	And @DBBackupLSN Between B.first_lsn And B.last_lsn
	Order By backup_finish_date, backup_set_id;

	-- Get last_lsn of the first log backup that will be restored
	Set @DBBackupLSN = Null;
	Select @DBBackupLSN = Max(last_lsn)
	From @Baks
	Where type = 'L';


	--select * from @Baks;

	-- Recursively get all log backups, in order, to be restored
	-- first_lsn of the log backup = last_lsn of the previous log backup
	With Logs
	As (Select B.backup_set_id,
			B.media_set_id,
			B.first_family_number,
			B.last_family_number,
			B.first_lsn,
			B.last_lsn,
			B.database_backup_lsn,
			B.backup_finish_date,
			B.type,
			BF.family_sequence_number,
			BF.physical_device_name,
			BF.device_type,
			1 As LogLevel
		From msdb.dbo.backupset B
		Inner Join msdb.dbo.backupmediafamily As BF
			On BF.media_set_id = B.media_set_id
				And BF.family_sequence_number Between B.first_family_number And B.last_family_number
		Where B.database_name = @DBName
		And B.is_copy_only = 0
		And B.type = 'L'
		And BF.physical_device_name Not In ('Nul', 'Nul:')
		And B.first_lsn = @DBBackupLSN
		and B.First_lsn <> B.Last_Lsn -- Anders 2016-02-26
		Union All
		Select B.backup_set_id,
			B.media_set_id,
			B.first_family_number,
			B.last_family_number,
			B.first_lsn,
			B.last_lsn,
			B.database_backup_lsn,
			B.backup_finish_date,
			B.type,
			BF.family_sequence_number,
			BF.physical_device_name,
			BF.device_type,
			L.LogLevel + 1
		From msdb.dbo.backupset B
		Inner Join msdb.dbo.backupmediafamily As BF
			On BF.media_set_id = B.media_set_id
				And BF.family_sequence_number Between B.first_family_number And B.last_family_number
		Inner Join Logs L On L.database_backup_lsn = B.database_backup_lsn
		Where B.database_name = @DBName
		And B.is_copy_only = 0
		And B.type = 'L'
		And BF.physical_device_name Not In ('Nul', 'Nul:')
		And B.first_lsn = L.last_lsn
		and B.First_lsn <> B.Last_Lsn) -- Anders 2016-02-26
	Insert Into @Baks (backup_set_id,
		media_set_id,
		first_family_number,
		last_family_number,
		first_lsn,
		last_lsn,
		database_backup_lsn,
		backup_finish_date,
		type,
		family_sequence_number,
		physical_device_name,
		device_type)
	Select backup_set_id,
		media_set_id,
		first_family_number,
		last_family_number,
		first_lsn,
		last_lsn,
		database_backup_lsn,
		backup_finish_date,
		type,
		family_sequence_number,
		physical_device_name,
		device_type
	From Logs
	Option(MaxRecursion 0);

	-- Select out just the columns needed to script restore
	IF OBJECT_ID('tempdb..#Baks') IS NOT NULL
		DROP TABLE #Baks

	Select RestoreOrder = Row_Number() Over(Partition By family_sequence_number Order By BakID),
		RestoreType = Case When type In ('D', 'I') Then 'Database'
				When type = 'L' Then 'Log'
			End,
		DeviceType = Case When device_type in (2, 102) Then 'Disk'
				When device_type in (5, 105) Then 'Tape'
			End,
		PhysicalFileName =  replace (physical_device_name, '\\agdata.int\backups\ebusiness\eBiz\MONSANTO\MONSANTO', '\\BU\AndersTest\AndersTest') 
	into #Baks -- to stop from having to read it twice, this could be done neater
	From @Baks
	Order By BakID;

	Set NoCount on;
	set quoted_identifier off;

	if @Output in (1,3) 
		select * from #Baks

	if @Output in (2,3)
	begin
	/****
	Anders 2016-11/28
	This could be done going into a temp table to create one output, but that would create a column name
	Done this way, the script can simply be copied and pasted to a new query window to be executed
	*****/
	
	
		select "restore database " + @DBName +" from DISK = '" + PhysicalFileName + "' with NORECOVERY" + case when RIGHT(PhysicalFileName, 3) = 'bak' then " , REPLACE" else "" end 
		from #Baks
		where RestoreType = 'Database'
		order by RestoreOrder

	

		select  "restore log " + @DBName +" from DISK = '" + PhysicalFileName + "' with NORECOVERY" 
		from #Baks
		where RestoreType = 'Log'
		order by RestoreOrder

		-- recover the database
		select "RESTORE DATABASE " +@DBName + " WITH RECOVERY"
	end
	

	Set NoCount Off;

END -- proc
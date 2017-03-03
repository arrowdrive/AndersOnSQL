use SQLSentry 
-- use SentryOne -- depends if new install, or upgrade

create procedure dbo.BatchDeletePerformanceAnalysisDataTableAndIndexCounterData
	@EndDateTime DateTime,
	@MaxIterations int = 1,
	@BatchSize int = 1000
as
/******************
Anders Pedersen
2017-01-18

Made to batch delete data out of the PerformanceAnalysisDataTableAndIndexCounter table.
Delete statement provided by SentryOne could not handle a lot of data without
a lot of manual intervention (manual batches).

This uses the column with the primary key on it for deletes instead of the timestamp column,
this substantially speeds up deletes.

*/

begin
	set nocount on
	--set DEADLOCK_PRIORITY low -- if you see a lot of other processes being victim, set this 
	--(unless it is more important to get it cleaned up than loosing a few records)
-- get first time stamp
	declare @BeginTimeStamp int, @EndTimeStamp int
	declare @BeginID bigint, @EndID bigint
-- sanity check, do not let it delete to a date less than 15 days back.  Making it 16 to cover the entire day.  Close enough
	if DATEDIFF(day, @EndDateTime, getdate()) <= 16 or @EndDateTime is null
		set @EndDateTime = DATEADD(day, -16, getdate()) 	
	select @EndTimeStamp = [dbo].[fnConvertDateTimeToTimestamp] (@EndDateTime)

	-- get ID for that newest one to delete
	select @EndID = max(id) from PerformanceAnalysisDataTableAndIndexCounter with (nolock) where Timestamp <= @EndTimeStamp -- this step takes time, 2ish minutes
	select @BeginID = min(id) from PerformanceAnalysisDataTableAndIndexCounter with (nolock) where ID <= @EndID

	declare @cnt  bigint = 0
	declare @X int = 1
	while @x <= @MaxIterations and @BeginID < @EndID
	begin
		if @x <> 1 -- skip wait on first iteration. Save time if you only running small batches
			waitfor DELAY '00:00:03'; -- 3 second delay to let transactions through.  This might need adjusted
		with CTE as
		(
			select top (@BatchSize) * from PerformanceAnalysisDataTableAndIndexCounter where ID between @BeginID and @EndID order by ID asc
		)
		delete from CTE
		select @cnt += @@ROWCOUNT 
		set @x +=1
	
	
	end 
	select @cnt as RecordsDeleted

end
	
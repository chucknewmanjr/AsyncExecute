--use DeadlockExperiment;
go

-- This schema is just for the the stuff in this deployment script.
IF SCHEMA_ID('Async') IS NULL EXEC ('CREATE SCHEMA [Async] AUTHORIZATION [dbo]');
GO

drop table if exists [Async].[ErrorLog];
go

-- Written into by the catch block in [Async].[p_ExecuteJobStep].
create table [Async].[ErrorLog] (
	ErrorLogID              int not null identity
		constraint PK_ErrorLog primary key clustered,
	ErrorLine               int not null, -- ERROR_LINE() from catch block.
	ErrorMessage  varchar(4000) not null, -- ERROR_MESSAGE() from catch block.
	SessionNumber           int not null, -- Sequential number used in the name of the job and passed along.
	SessionID               int not null, -- @@SPID for a job.
);
go

CREATE OR ALTER PROC [Async].[p_DeleteJobs] as
	/*
		This proc deletes all the jobs 
		with names that begin with "Temporary Session Job - ".
		It's called by [Async].[p_Execute].
		But it can also be used after calling [Async].[p_Execute].
		It does not check if those jobs are running.
		That's what [Async].[p_CountJobsRunning] is for.

		declare @JobsRunningCount tinyint;
		EXEC @JobsRunningCount = [Async].[p_CountJobsRunning];
		if @JobsRunningCount = 0 EXEC [Async].[p_DeleteJobs];
	*/
	set nocount, xact_abort on;

	declare @JobNamePrefix sysname = 'Temporary Session Job - ';

	-- Build the set of delete instructions.
	-- Cast as max so it can handle lots of jobs.
	declare @JobDeleteStatements nvarchar(max) = (
		select STRING_AGG(cast('EXEC msdb.dbo.sp_delete_job @job_name = ''' + name + ''';' as varchar(max)), ' ')
		from msdb.dbo.sysjobs
		where name like @JobNamePrefix + '%'
	);

	-- Execute all the instructions at once.
	exec (@JobDeleteStatements);
go

CREATE OR ALTER proc [Async].[p_CountJobsRunning] as
	/*
		This proc returns the number jobs running
		with names that begin with "Temporary Session Job - ".
		It's called by both [Async].[p_Execute] and [Async].[p_WaitUntilDone].
		The key to doing this correctly is the session_id. 
		It has to be the latest from msdb.dbo.syssessions.

		declare @JobsRunningCount int = 1;
		while @JobsRunningCount > 0 begin;
			WAITFOR DELAY '00:00:01.000'; -- Wait a sec.
			EXEC @JobsRunningCount = [Async].[p_CountJobsRunning];
		end;
	*/
	set nocount, xact_abort on;

	declare @JobNamePrefix sysname = 'Temporary Session Job - ';

	return (
		SELECT COUNT(*)
		FROM msdb.dbo.sysjobactivity a
		JOIN msdb.dbo.sysjobs j ON a.job_id = j.job_id
		WHERE j.name like @JobNamePrefix + '%'
			-- Only check the latest session_id.
			and a.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
			AND a.start_execution_date IS NOT NULL
			AND a.stop_execution_date IS NULL
	);
GO

create or alter function [Async].[f_IsolationLevel]() 
returns varchar(50)
begin;
	/*
		Returns the name of the transaction isolation level.

		select [Async].[f_IsolationLevel]();
	*/
	declare @IsRCSI bit = (
			select is_read_committed_snapshot_on
			from sys.databases
			where database_id = db_id()
	);

	return (
		select CHOOSE(
				transaction_isolation_level + 1
				, 'Unspecified'
				, 'Read Uncommitted'
				, iif(@IsRCSI = 0
					, 'Read Committed'
					, 'Read Committed Snapshot'
				)
				, 'Repeatable Read'
				, 'Serializable'
				, 'Snapshot'
			)
		from sys.dm_exec_sessions
		where session_id = @@SPID
	);
end;
go

create or alter proc [Async].[p_ExecuteJobStep] 
	@CommandText nvarchar(max),
	@Seconds int,
	@SessionNumber tinyint
as
	/*
		Repeatedly execute @CommandText for a few seconds.
		It's intended to be called by jobs.
		The jobs are created by [Async].[p_Execute].
		@CommandText is executed in a transaction.
		If it fails, a row is written to [Async].[ErrorLog].

		EXEC [Async].[p_ExecuteJobStep] 
			@CommandText = 'EXEC [dbo].[p_DoTheThingy];'
			, @Seconds = 5
			, @SessionNumber = 1;
	*/
	set nocount, xact_abort on;

	declare @Start datetime2(2) = sysdatetime();

	while DATEDIFF(second, @Start, sysdatetime()) < @Seconds begin;
		begin try;
			begin tran;

			-- ================================================================
			exec (@CommandText);
			-- ================================================================

			commit;
		end try
		begin catch;
			-- Rollback ... but only if you can.
			if XACT_STATE() <> 0 rollback;

			-- Record the error.
			insert [Async].[ErrorLog] (ErrorLine, ErrorMessage, SessionNumber, SessionID)
			values (ERROR_LINE(), ERROR_MESSAGE(), @SessionNumber, @@SPID);

			-- Continue looping instead of rethrowing the error.
		end catch;
	end;
go

create or alter proc [Async].[p_Execute]
	@CommandText nvarchar(max), -- Include [SessionNumber] if you want.
	@Seconds int, -- Seconds to run each session.
	@SessionCount tinyint -- Number of jobs to create.
as
	/*
		Creates and executes jobs that all run at the same time.
		That's because each job runs in its own session.
		The sp_start_job command returns imediately 
		even though the job is still running.

		- @CommandText - SQL instructions to get repeatedly executed.
			That command text can contain "[SessionNumber]".
			It gets replaced with a number for each job.
		- @Seconds - The number of seconds to keep executing @CommandText.
		- @SessionCount - The number of temporary jobs to be created.

		EXEC [Async].[p_Execute] 'WAITFOR DELAY ''00:00:01.000''; PRINT ''~[SessionNumber]~'';', 5, 5;

		EXEC [Async].[p_WaitUntilDone];

		SELECT distinct * 
		FROM [Async].[v_Sessions] m
		cross apply string_split(m.message, '~') v
		where TRY_CAST(v.value as int) is not null;
	*/
	set nocount, xact_abort on;

	declare @JobNamePrefix sysname = 'Temporary Session Job - ';
	declare @JobsRunningCount tinyint;
	declare @SessionNumber tinyint;
	declare @JobName sysname;
	declare @Command nvarchar(max);
	declare @DatabaseName sysname = db_name();

	print concat_ws(' - ', sysdatetime(), 'Check for jobs running.');

	-- Check if any of the jobs like this are still running.
	EXEC @JobsRunningCount = [Async].[p_CountJobsRunning];

	-- Error out if any are still running.
	if @JobsRunningCount <> 0 throw 50000, 'A job is still running.', 1;

	print concat_ws(' - ', sysdatetime(), 'Delete jobs.');

	-- Delete these jobs.
	EXEC [Async].[p_DeleteJobs];

	print concat_ws(' - ', sysdatetime(), 'Create a job for each session.');

	-- Starting at zero is fine since it gets incremented at the top of the loop.
	set @SessionNumber = 0;

	-- Using less-than is fine since ... increment.
	while @SessionNumber < @SessionCount begin;
		set @SessionNumber += 1;

		-- Each job gets its own name.
		set @JobName = concat(@JobNamePrefix, @SessionNumber);

		-- create the job.
		EXEC msdb.dbo.sp_add_job 
			@job_name = @JobName;

		-- The command might have the [SessionNumber] placeholder in it.
		set @Command = replace(@CommandText, '[SessionNumber]', @SessionNumber);

		-- The command is likely to have single quotes in it.
		set @Command = REPLACE(@Command, '''', '''''');

		-- Get that other proc to execute it in a transaction.
		set @Command = CONCAT( 
			'EXEC [Async].[p_ExecuteJobStep] ',
			'@CommandText = ''', @Command + ''', ',
			'@Seconds = ', @Seconds, ', ',
			'@SessionNumber = ', @SessionNumber, ';'
		);

		-- Put that command into a single step inside of that job.
		EXEC msdb.dbo.sp_add_jobstep 
			@job_name = @JobName, 
			@step_name = N'Single Job Step', 
			@Command = @Command, 
			@database_name = @DatabaseName;

		-- Creating a job does not set the target server to the obvious choice.
		EXEC msdb.dbo.sp_add_jobserver 
			@job_name = @JobName, 
			@server_name = N'(local)';
	end; -- End while @SessionNumber <= @SessionCount loop.

	-- Jobs are started in a separate loop so that they start closer together.
	print concat_ws(' - ', sysdatetime(), 'Run the job for each session.');

	truncate table [Async].[ErrorLog];

	set @SessionNumber = 0;

	while @SessionNumber < @SessionCount begin;
		set @SessionNumber += 1;

		set @JobName = concat(@JobNamePrefix, @SessionNumber);

		-- Start it asychronusly.
		EXEC msdb.dbo.sp_start_job @job_name = @JobName;
	end; -- End while @SessionNumber <= @SessionCount

	print concat_ws(' - ', sysdatetime(), 'All started.');
go

create or alter proc [Async].[p_WaitUntilDone]
as
	/*
		Keep looping until all the jobs are done.

		EXEC [Async].[p_WaitUntilDone];
	*/
	set nocount, xact_abort on;

	print concat_ws(' - ', sysdatetime(), 'Start waiting for jobs to end.');

	declare @JobNamePrefix sysname = 'Temporary Session Job - ';
	declare @JobsRunningCount tinyint = 1;

	while @JobsRunningCount > 0 begin;
		WAITFOR DELAY '00:00:01.000'; -- Wait a sec.

		-- Check again.
		EXEC @JobsRunningCount = [Async].[p_CountJobsRunning];
	end;

	print concat_ws(' - ', sysdatetime(), 'Jobs are all done.');
go

CREATE or alter view [Async].[v_Sessions] as
	/*
		This view returns a row for each job/session with 6 columns:
			- SessionNumber - It's cut from the job name.
			- RunStatus - 5 text values. It's usually Succeeded or Failed.
			- sql_severity - Severity number of SQL Server error. Usually zero.
			- message - From print statements and error messages.
			- StartTime
			- RunSeconds

		SELECT * FROM [Async].[v_Sessions];

		SELECT * 
		FROM [Async].[v_Sessions] m
		cross apply string_split(m.message, '~') v
		where TRY_CAST(v.value as int) is not null;
	*/
	select cast(trim(substring(
			j.[name], 
			len('Temporary Session Job - ') + 1, 
			99
		)) as int) as SessionNumber
		, choose(h.run_status + 1
			, 'Failed'
			, 'Succeeded'
			, 'Retry'
			, 'Canceled'
			, 'In progress'
		) as RunStatus
		, h.sql_severity
		, h.[message]
		, MSDB.DBO.AGENT_DATETIME(h.run_date, h.run_time) as StartTime
		, h.run_duration / 10000 * 3600 
			+ h.run_duration % 10000 / 100 
			* 60 + h.run_duration % 100 as RunSeconds
	from msdb.dbo.sysjobs j
	join msdb.dbo.sysjobhistory h on h.job_id = j.job_id
	where j.name like 'Temporary Session Job - %'
		and step_id = 1;
go

create or alter view [Async].[v_Locks] as
	/*
		Like sp_lock execept decoded.
		Call it while the sessions are running.
		So between Execute and WaitUntilDone.

		select * 
		from [Async].[v_Locks]
		order by TableName, IndexName, SessionID;
	*/
	with indexes as (
		select p.hobt_id, p.object_id, i.name as IndexName
		from sys.indexes i 
		join sys.partitions p
		on i.object_id = p.object_id and i.index_id = p.index_id
	)
	select ISNULL(
			OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id),
			OBJECT_SCHEMA_NAME(o.object_id) + '.' + OBJECT_NAME(o.object_id)
		) as TableName
		, i.IndexName
		, l.request_session_id as SessionID
		, l.resource_type as ResourceType
		, l.request_mode as Mode
		, COUNT(*) as Occurs
		, t.blocking_session_id as BlockingSessionID
	from sys.dm_tran_locks l
	left join sys.objects o on o.object_id = l.resource_associated_entity_id -- OBJECT
	left join indexes i on i.hobt_id = l.resource_associated_entity_id -- KEY, PAGE
	left join sys.dm_os_waiting_tasks t on t.resource_address = l.lock_owner_address
	where resource_database_id = DB_ID()
	group by l.resource_type
		, l.request_mode
		, l.request_session_id
		, o.object_id
		, i.object_id
		, i.IndexName
		, t.blocking_session_id;
go

create or alter proc [Async].[p_GetDeadlocks] @MinutesAgo int = 60 as
	/*
		Just a summary of resent deadlocks.
		Deadlocks can take a minute to show up here.
		You're better off going to 
		SSMS > Management > Extended Events > Sessions > system_health > event_file.

		EXEC [Async].[p_GetDeadlocks] 20;
	*/
	set nocount, xact_abort on;

	SELECT IDENTITY(int) as DeadlockID
		, cast(timestamp_utc as datetime2(2)) as timestamp_utc
		, cast(event_data as xml) as event_data
	into #Deadlocks
	FROM sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL)
	WHERE object_name = 'xml_deadlock_report'
		and cast(timestamp_utc as datetime2(7)) > DATEADD(minute, -@MinutesAgo, SYSUTCDATETIME())
	order by timestamp_utc desc;

	select d.DeadlockID
		, d.timestamp_utc
		, p.Process.value('@id', 'varchar(50)') as ProcessID
	into #Victim
	from #Deadlocks d
	cross apply d.event_data.nodes('/event/data/value/deadlock/victim-list/victimProcess') as p(Process)

	select d.DeadlockID
		, d.timestamp_utc
		, p.Process.value('@spid', 'int') as SPID
		, p.Process.value('@id', 'varchar(50)') as ProcessID
		, p.Process.value('(executionStack/frame/@line)[1]', 'int') as Line
	into #Process
	from #Deadlocks d
	cross apply d.event_data.nodes('/event/data/value/deadlock/process-list/process') as p(Process)

	--select d.*, p.Process.query('.')
	--from #Deadlocks d
	--cross apply d.event_data.nodes('/event/data/value/deadlock/resource-list/keylock') as p(Process)

	select d.DeadlockID
		, d.timestamp_utc
		, p.Resource.value('(owner-list/owner/@id)[1]', 'varchar(50)') as OwnerProcessID
		, p.Resource.value('(owner-list/owner/@mode)[1]', 'varchar(20)') as OwnerMode
		, p.Resource.value('(waiter-list/waiter/@id)[1]', 'varchar(50)') as WaiterProcessID
		, p.Resource.value('(waiter-list/waiter/@mode)[1]', 'varchar(20)') as WaiterMode
	into #Resource
	from #Deadlocks d
	cross apply d.event_data.nodes('/event/data/value/deadlock/resource-list/keylock') as p(Resource)

	select p.timestamp_utc
		, p.SPID
		, p.Line
		, IIF(v.ProcessID is null, '', 'Victim') as Result
		, o.OwnerMode as Owns
		, w.WaiterMode as WaitingOn
	from #Process p
	join #Resource o on o.DeadlockID = p.DeadlockID and o.OwnerProcessID = p.ProcessID
	join #Resource w on w.DeadlockID = p.DeadlockID and w.WaiterProcessID = p.ProcessID
	left join #Victim v on v.DeadlockID = p.DeadlockID and v.ProcessID = p.ProcessID
	order by p.DeadlockID, p.ProcessID;
go

with p as (
	select p.object_id,
		STRING_AGG(concat_ws(' '
			, isnull(nullif(p.name, ''), '(return value)')
			, TYPE_NAME(p.user_type_id)
			, p.max_length
		), ', ') within group (order by p.parameter_id) as Parameters
	from sys.parameters p
	where OBJECT_SCHEMA_NAME(p.object_id) = 'Async'
	group by p.object_id
)
select CONCAT_WS('.', OBJECT_SCHEMA_NAME(o.object_id), OBJECT_NAME(o.parent_object_id), o.name) as Thing
	, o.type_desc
	, DATEDIFF(MINUTE, o.modify_date, SYSDATETIME()) as MinsOld
	, Parameters
from sys.objects o
left join p on p.object_id = o.object_id
where schema_id = SCHEMA_ID('Async')
	or o.modify_date > DATEADD(second, -1, SYSDATETIME())
order by Thing;



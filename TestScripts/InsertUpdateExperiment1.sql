use ConcurrencyExperiment;
go

drop table if exists [dbo].[Transaction];
go

create table [dbo].[Transaction] (
	TransactionID int not null identity 
		constraint PK_Transactions primary key clustered
	, TransactionCode int not null
		constraint UX_TransactionCode unique
	, Occurred int not null
);
go

create or alter proc [dbo].[p_PerformTransactions] as
	set nocount, xact_abort on;

	--set transaction isolation level serializable;

	create table #Data (
		TransactionCode int not null,
	);

	insert #Data with (tablockx) (TransactionCode)
	SELECT CHECKSUM(newid()) % 10000
	FROM GENERATE_SERIES(1, 100);

	update [dbo].[Transaction]
	set Occurred += 1
	from [dbo].[Transaction] targt --with (updlock, holdlock, rowlock)
	join #Data src on src.TransactionCode = targt.TransactionCode;

	insert [dbo].[Transaction] (TransactionCode, Occurred)
	select src.TransactionCode, 1
	from #Data src
	where not exists (
			select *
			from [dbo].[Transaction] targt --with (updlock, holdlock, rowlock)
			where targt.TransactionCode = src.TransactionCode
		);
go

EXEC [Async].[p_Execute] 
	@CommandText = 'EXEC [dbo].[p_PerformTransactions];'
	, @Seconds = 5
	, @SessionCount = 2

exec [Async].[p_WaitUntilDone];

with e as (
	select ErrorLine, 
		case 
			when ErrorMessage like '%Violation of UNIQUE KEY %' then 'UNIQUE KEY Violation'
			when ErrorMessage like '%deadlocked%' then 'deadlocked'
			else 'Other'
		end as ErrorType
	from [Async].[ErrorLog]
)
select ErrorLine, ErrorType, COUNT(*) as ErrorCount
from e
group by ErrorLine, ErrorType;

select COUNT(*) as TotalInserts, SUM(Occurred - 1) as TotalUpdates -- select *
from [dbo].[Transaction];

/*
	select * from [Async].[ErrorLog] order by SessionNumber;

	select * from [Async].[v_Sessions] order by SessionNumber;
--*/



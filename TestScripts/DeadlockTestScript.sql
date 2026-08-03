use DeadlockExperiment;
go

drop table if exists dbo.Transactions;
drop table if exists dbo.TestData;
go

create table dbo.Transactions (
	TransactionID int not null identity constraint PK primary key clustered,
	TransactionCode int index IX_TransactionCode,
);
go

create table dbo.TestData (TransactionCode int not null);
go

insert dbo.TestData values (CHECKSUM(newid()) % 10000);
go 5 -- insert 5 rows

create or alter proc [dbo].[p_PerformTransactions] 
	@SessionNumber tinyint
as
	/*
		EXEC [dbo].[p_PerformTransactions] 1;
	*/
	set nocount, xact_abort on;

	declare @Start datetime2(2) = sysdatetime();

	while DATEDIFF(second, @Start, sysdatetime()) < 5 begin; 
		-- Generate test data.
		update dbo.TestData
		set TransactionCode = CHECKSUM(newid()) % 10000;

		begin try;
			-- Put update and insert in a transaction.
			begin tran;

			update dbo.Transactions
			set TransactionCode = CHECKSUM(newid()) % 10000
			from dbo.Transactions targt
			join dbo.TestData src on src.TransactionCode = targt.TransactionCode;

			insert dbo.Transactions (TransactionCode)
			select TransactionCode
			from dbo.TestData src
			where not exists (
					select *
					from dbo.Transactions targt
					where targt.TransactionCode = src.TransactionCode
				);

			commit;
		end try
		begin catch;
			rollback;
			print concat('~', error_line(), '~');
			throw;
		end catch;
	end;
go

EXEC [Async].[p_GetTransactionIsolationLevel];
go

EXEC [Async].[p_Execute] 10, 'EXEC [dbo].[p_PerformTransactions] ''[SessionNumber]'';', 0;
go

with ErrorLines as (
	select m.SessionNumber, v.value as LineNumber
	FROM [Async].[f_SessionMessage](DEFAULT) m
	cross apply string_split(message, '~') v
	where TRY_CAST(v.value as int) is not null
)
select cast(sm.SessionNumber as int) as SessionNumber
	, sm.RunStatus
	, sm.RunSeconds
	, sm.[Message]
	, el.LineNumber
from [Async].[f_SessionMessage](DEFAULT) sm
left join ErrorLines el on el.SessionNumber = sm.SessionNumber
order by 1;
go



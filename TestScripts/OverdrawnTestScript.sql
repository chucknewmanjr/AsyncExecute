use OverdrawnExperiment;
go

drop table if exists [dbo].[Balance];
go

create table [dbo].[Balance] (
	UserID int not null identity constraint PK primary key clustered,
	Amount decimal(19,2) not null,
);
go

set nocount on;
go

insert into [dbo].[Balance] (Amount) 
values (100000000000000);
go 100 -- <== Do the insert this many times.

create or alter proc [dbo].[p_Withdraw] as
	/*
		EXEC [dbo].[p_Withdraw];
	*/
	set nocount, xact_abort on;

	declare @ThisLoop int = 0;

	while @ThisLoop < 1000 begin;
		set @ThisLoop += 1;

		declare @UserID int = (
			select CHECKSUM(newid()) % MAX(UserID) + 1
			from [dbo].[Balance]
		);

		begin try;

			begin tran;

			-- The withdrawal is a little more than half (60%) of the balance.
			-- If that amount is accidentally withdrawn twice, 
			-- the account becomes overdrawn.
			declare @Withdrawal decimal(19,2) = (
				select Amount * 0.6
				from [dbo].[Balance]
				where UserID = @UserID
			);

			update [dbo].[Balance]
			set Amount -= @Withdrawal
			where UserID = @UserID;

			if (
				select Amount
				from [dbo].[Balance]
				where UserID = @UserID
			) < 0
				throw 50000, 'Account overdrawn.', 1;

			commit;
		end try
		begin catch;
			if XACT_STATE() <> 0 rollback;

			throw; -- Rethrow the error.
		end catch;
	end;
go

EXEC [Async].[p_GetTransactionIsolationLevel];

EXEC [Async].[p_Execute] 100, 'EXEC [dbo].[p_Withdraw];'; 

WAITFOR DELAY '00:00:01.000'; -- Wait a sec.

select * 
from [Async].[v_Locks] 
where SessionID <> @@SPID and ResourceType <> 'DATABASE'
order by TableName, IndexName, SessionID, ResourceType;

select Amount, COUNT(*) from [dbo].[Balance] group by Amount;

EXEC [Async].[p_Wait];

select * from [Async].[f_SessionMessage](DEFAULT) order by 1;

select Amount, COUNT(*) from [dbo].[Balance] group by Amount;



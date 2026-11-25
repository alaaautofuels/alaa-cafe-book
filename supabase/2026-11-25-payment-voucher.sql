-- Payment metadata travels with the balanced lines through existing snapshot and audit paths.
create or replace function public.validate_payment_voucher()
returns trigger language plpgsql set search_path='' as $$
declare d jsonb:=new.lines->0; c jsonb:=new.lines->1; dest text:=d->>'particulars'; src text:=c->>'particulars';
begin
 if tg_op='UPDATE' and (old.lines->0->>'voucherType'='Payment') is distinct from (d->>'voucherType'='Payment') then
  raise exception 'Voucher type cannot be changed';
 end if;
 if tg_op='UPDATE' and old.lines=new.lines and old.voucher_date=new.voucher_date and old.remark is not distinct from new.remark then return new; end if;
 if not exists(select from jsonb_array_elements(new.lines) l where l ? 'voucherType') then return new; end if;
 if (jsonb_array_length(new.lines)=2 and d->>'voucherType'='Payment' and c->>'voucherType'='Payment'
 and d->>'side'='debit' and c->>'side'='credit' and src in ('Cash','UPI Account','Bank')
 and dest not in ('Cash','Bank','Sales','Cash Sale','Purchases','UPI','UPI Account')
 and d->>'purpose' in ('advance','supplier','expense') and c->>'purpose'=d->>'purpose'
 and (dest not in ('Expenses','Other Expenses') or d->>'purpose'='expense')
 and d->>'postingRule'='account-normal-v1' and c->>'postingRule'='account-normal-v1'
 and not (d ? 'transferRole' or c ? 'transferRole') and (d->>'amount')::numeric between 0.01 and 9999999999.99
 and (d->>'amount')::numeric=round((d->>'amount')::numeric,2)
 and (d->>'amount')::numeric=(c->>'amount')::numeric and new.voucher_date is not null) is not true then
  raise exception 'Invalid payment voucher' using errcode='22023';
 end if;
 if exists(select from public.journal_account_options where cafe_id=new.cafe_id and account_name in (src,dest) and not enabled)
 or (dest<>'Other Expenses' and not exists(select from public.journal_account_options where cafe_id=new.cafe_id and account_name=dest and enabled)) then
  raise exception 'Choose an enabled payment account';
 end if;
 return new;
end;
$$;
drop trigger if exists validate_payment_voucher on public.journal_vouchers;
create trigger validate_payment_voucher before insert or update on public.journal_vouchers
for each row execute function public.validate_payment_voucher();
create or replace function public.save_payment_voucher_checked(p_cafe_id uuid,p_id uuid,p_expected_updated_at timestamptz,p_voucher_date date,p_remark text,p_lines jsonb)
returns public.journal_vouchers language plpgsql security invoker set search_path='' as $$
begin
 if p_id is null or (p_lines->0->>'voucherType') is distinct from 'Payment' then raise exception 'Payment voucher required'; end if;
 return public.save_journal_voucher_checked(p_cafe_id,p_id,p_expected_updated_at,p_voucher_date,p_remark,p_lines);
end;
$$;
revoke all on function public.save_payment_voucher_checked(uuid,uuid,timestamptz,date,text,jsonb) from public,anon;
grant execute on function public.save_payment_voucher_checked(uuid,uuid,timestamptz,date,text,jsonb) to authenticated;

alter table public.journal_vouchers add column if not exists voucher_type text
 generated always as (case when lines->0->>'voucherType'='Payment' then 'Payment' else 'Journal' end) stored;

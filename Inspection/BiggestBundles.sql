 
select 
  pat.bundle_id, 
  disp.quant, 
  pat.contacts
from contacts_displayed disp
join pat on pat.bundle_id = disp.bundle_id
where disp.quant > 4
order by quant desc;

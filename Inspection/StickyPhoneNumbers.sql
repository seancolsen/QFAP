/* find phone numbers that are creating large bundles */ 


set @min_dedication = 
  (select min(lh_dedication) from bundle where is_chosen = 1); 

set @min_meat = 
  (select min(aa_meat) from bundle where is_chosen = 1); 
  
  
drop temporary table if exists contact_unique_phones;
create temporary table contact_unique_phones (
  contact_id int(10), 
  phone char(12), 
  index(contact_id),
  index(phone),
  unique index(contact_id, phone) ); 
insert into contact_unique_phones select 
  contact_id, 
  phone_compare
from contact_phones
group by contact_id, phone_compare; 


select 
  bundle.id,
  cp.phone, 
  count(distinct cb.contact_id) as contacts_with_phone,
  disp.quant as contacts_displayed,
  pat.contacts
from bundle 
join contact_bundle cb on cb.bundle_id = bundle.id 
join pat on pat.bundle_id = bundle.id 
join contact_unique_phones cp on cp.contact_id = cb.contact_id 
join contacts_displayed disp on disp.bundle_id = bundle.id 
where 
  lh_dedication > @min_dedication and 
  aa_meat > @min_meat
group by cp.phone
having 
  contacts_with_phone >= 2 and 
  contacts_displayed >= 3 and 
  ( contacts_with_phone >= 3 OR contacts_displayed >= 4 )
order by contacts_displayed desc, bundle.id,  contacts_with_phone desc;
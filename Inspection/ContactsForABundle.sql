/* contacts for a bundle */ 
select 
  bundle.id as bundle_id,
  bundle.contact_types, 
  bundle.quant_total,
  bundle.priority,
  contact.id contact_id, 
  contact.display_name,
  contact.contact_type,
  clout.clout
from contact_bundle cb
join civicrm_contact contact on contact.id = cb.contact_id 
join bundle on bundle.id = cb.bundle_id
join clout on clout.contact_id = contact.id
where  
  bundle.contact_types like '%O%' and bundle.is_chosen = 1
  /* bundle.id in (1238, 3419, 3446, 5766, 6157, 13329, 16278, 17468, 25711) */
order by bundle.quant_total desc, bundle.priority desc, bundle.id, contact.contact_type;


/* how many names? */
select quant, count(*) as num 
from contacts_displayed 
group by quant



set @bundle_id = 54075; 

/* contribs for a bundle */ 
select 
  contact.id as contact_id,
  contrib.id as contrib_id,
  contact.display_name contact,
  date_format(contrib.receive_date,'%Y-%m-%d') as 'date',
  format(contrib.total_amount,0) as amount,
  t.name as 'type'
from civicrm_contribution contrib
join civicrm_financial_type t on t.id = contrib.financial_type_id
join civicrm_contact contact on contact.id = contrib.contact_id
join contact_bundle cb on cb.contact_id = contrib.contact_id 
where contrib.contribution_status_id = 1 and cb.bundle_id = @bundle_id
order by cb.bundle_id, contrib.receive_date desc;

/* bundle */ 
select * from bundle;
select * from bundle where id = 3254;
update bundle set list_order = null, is_chosen =0, is_fresh = 0;

select @fresh_included_count; 

/* solicitation list */ 
select id, quant_total, aa_round, likelihood, priority, difficulty, list_order, pile
from bundle /* left join bundle_name on bundle_name.bundle_id = bundle.id  */
where is_chosen = 1
order by pile limit 10000;

/* thanks */ 
select * 
from bundle
left join special_thanks thx on thx.bundle_id = bundle.id 
where bundle.is_chosen = 1 and thx.bundle_id is null 
order by bundle.aa_raw desc;


/* contact types */ 
select quant_total, contact_types, count(*) as num
from bundle where is_chosen = 1 group by quant_total,contact_types;
select * from bundle where contact_types = 'O' and is_excluded = 0; 


/* bundles with more than one household */ 
select 
  bundle.id as bundle_id,
  bundle.contact_types, 
  bundle.quant_total,
  bundle.priority
from contact_bundle cb
join civicrm_contact contact on contact.id = cb.contact_id 
join bundle on bundle.id = cb.bundle_id
where  
  contact.contact_type = 'Household' and 
  bundle.is_chosen = 1
group by bundle.id 
having count(*) > 1;

select 
  bundle.id as bundle_id,
  bundle.contact_types, 
  bundle.quant_total,
  bundle.priority
from bundle 
where contact_types = 'I' and quant_total >= 3 and bundle.is_chosen = 1;


/* inspect thanks */ 
select bundle.id, aa_round, likelihood, priority, thanks
from bundle
left join special_thanks thx on thx.bundle_id = bundle.id 
where bundle.is_chosen = 1 
order by priority desc

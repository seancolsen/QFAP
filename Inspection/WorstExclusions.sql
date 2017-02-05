

set group_concat_max_len = 300;

drop temporary table if exists simple_contrib_summary; 
create temporary table simple_contrib_summary (
  bundle_id int(10), 
  summary text, 
  unique index(bundle_id) ); 
insert into simple_contrib_summary select 
  cb.bundle_id,
  group_concat( concat(
    '$',format(contrib.total_amount,0), ' ',
    substr(
        t.name, 
        locate('(',t.name) + 1, 
        locate(')',t.name) - locate('(',t.name) - 1 
      ), ' ',
    date_format(contrib.receive_date,'%Y-%b'), ' ',
	'#',contact.id
    ) order by contrib.receive_date desc separator '\n' ) as summary 
from civicrm_contribution contrib
join civicrm_financial_type t on t.id = contrib.financial_type_id
join civicrm_contact contact on contact.id = contrib.contact_id
join contact_bundle cb on cb.contact_id = contrib.contact_id 
where contrib.contribution_status_id = 1
group by cb.bundle_id ;

set group_concat_max_len = 10240;


drop temporary table if exists most_recent_pat; 
create temporary table most_recent_pat (
  bundle_id int(10), 
  donation_year int(4), 
  unique index(bundle_id) ); 
insert into most_recent_pat select 
  cb.bundle_id, 
  max(year(contrib.receive_date)) as donation_year
from contact_bundle cb 
join civicrm_contribution contrib on contrib.contact_id = cb.contact_id
join civicrm_financial_type ct on ct.id = contrib.financial_type_id 
where 
  ct.id = 9 /* PAT */ and 
  contrib.contribution_status_id = 1
group by cb.bundle_id;





set @lowest_priority = (select min(priority) from bundle where is_chosen = 1); 

/* worst exclusions */ 

select 
  b.id as bundle_id, 
  b.aa_raw, 
  b.likelihood, 
  b.priority, 
  group_concat( concat(
    coalesce(upper(strat.name), 'OK'), ': ',
    contact.display_name, 
	coalesce(concat(' (',sit.name,')'),''), 
    ' #',contact.id
    ) order by strat.importance desc separator '\n' ) as exclusions,
  simple_contrib_summary.summary as contribs, 
  max(strat.importance) as max_importance,
  coalesce(most_recent_pat.donation_year,'') as pat
from bundle b
join contact_bundle cb on cb.bundle_id = b.id
join civicrm_contact contact on contact.id = cb.contact_id
left join exclude x on x.contact_id = cb.contact_id
left join exclude_situation sit on sit.name = x.situation
left join exclude_strategy strat on strat.name = sit.strategy
left join simple_contrib_summary on simple_contrib_summary.bundle_id = b.id
left join most_recent_pat on most_recent_pat.bundle_id = b.id 
where 
  b.is_excluded = 1 and  
  b.priority > @lowest_priority
group by b.id
order by b.priority desc
limit 10000;



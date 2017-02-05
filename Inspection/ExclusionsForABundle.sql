

/* exclusions */ 
select 
  strat.importance, sit.strategy, sit.name, count(*) as num
from exclude x
join exclude_situation sit on sit.name = x.situation
join exclude_strategy strat on strat.name = sit.strategy
group by situation
order by strat.importance desc, sit.name;


/* bundle report */ 
select 
  b.id as bundle_id,
  b.is_excluded as bundle_excluded,
  strat.importance as importance,
  strat.name as strategy, 
  contact.id as contact_id, 
  contact.display_name as contact_name, 
  sit.name as exclusion_situation
from bundle b
join contact_bundle cb on cb.bundle_id = b.id
join civicrm_contact contact on contact.id = cb.contact_id
left join exclude x on x.contact_id = cb.contact_id
left join exclude_situation sit on sit.name = x.situation
left join exclude_strategy strat on strat.name = sit.strategy
where b.id = @bundle_id
order by b.id, strat.importance desc, contact.id, sit.name




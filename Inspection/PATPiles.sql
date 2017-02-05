 
select 
  assignment,
  count(*) as quant,
  concat(min(pat.page),' - ',max(pat.page)) as pages,
  concat('$',format(min(aa_round), 0),' - $',format(max(aa_round),0)) as ask_amount,
  concat(format(100*min(bundle.likelihood), 0),'% - ',format(100*max(bundle.likelihood),0),'%') as likelihood,
  concat(format(min(bundle.priority), 3),' - ',format(max(bundle.priority),3),'') as priority,
  concat(format(min(bundle.difficulty), 0),' - ',format(max(bundle.difficulty),0),'') as difficulty

from pat 
join bundle on bundle.id = pat.bundle_id
group by assignment
order by pat.thanks, bundle.pile
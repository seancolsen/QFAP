select 
  page,
  pcid, 
  all_contact_ids, 
  bundle_id, 
  name, 
  contacts,
  /* contribs, */
  print_group, 
  pile, 
  aa_raw as ask_raw,
  ask,
  likelihood,
  priority, 
  difficulty, 
  ca as call_attempts, 
  thanks
from pat
limit 10000;
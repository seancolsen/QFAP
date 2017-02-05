 
select 
print_group, 
count(*) as num,
min(page) as page_start, 
max(page) as page_end
from pat
group by print_group
order by page_start


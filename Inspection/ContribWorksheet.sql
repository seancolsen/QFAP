
/* contrib_worksheet */ 

select * from contrib_worksheet;
select * from contrib_worksheet where cid is null;
select * from contrib_worksheet where bundle_id in (14054); 

select * from contrib_worksheet 
where is_first = 1 and cid is not null order by db;


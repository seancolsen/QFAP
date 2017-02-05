/* 
                              QFAP System

           Quantitative Fundraising Appeal Prioritization System


/**************************************************************************/
/**************************************************************************/
/***                                                                    ***/
/***                    Input and to-do items                           ***/
/***                                                                    ***/
/**************************************************************************/
/**************************************************************************/


/* ====================================================================== */
/*                      To do before running:                             */
/* ======================================================================

+ Set the search type below

+ Normalize phone numbers, if you're doing a PAT search. 

+ Make sure the DM has been recorded as an activity if doing PAT. 

+ Check to see if any new financial types have been added to CiviCRM and 
  update the financial_type_weights data in this script 
  
+ Merge duplicates 

*/ 

/* ====================================================================== */
/*                      INPUT                                             */
/* ====================================================================== */ 


set @solicitation_type = 'PAT'; 
/* DM or PAT. Use 'DM' when running a direct mail search or set 'PAT' when 
  running a Phone-A-Thon search.  */ 

set @now = '2016-11-30'; 
/* the approximate date of solicitation. For DM, this would be when the letter 
  hits the mailboxes. For PAT this would be when the call session start */ 

set @fresh_bundle_inclusion_window_years = 
  case @solicitation_type 
    when 'DM' then 0 /*years*/ + /*and*/ 9 /*months*/ /12 
    when 'PAT' then 0 
  end; 
/* For the DM it's important to mail to people that have never given. And we 
want to be able to ensure that people will receive the mailing if they've been
in our database for a certain amount of time without having given. So this 
setting allows us to force-include these people even if their priority is low. 
After including these bundles in the list, then the rest of the list is filled 
up to the brim in order of highest priority in order to achieve the desired 
results quantity as indicated below */ 

set @desired_results_quantity = 2000; 
/* how many results do we want in the final solicitation list? */ 


set @priority_level_divisions = 20; 
/* when making the PAT piles, how many different priority levels do we want? */

set @difficulty_level_divisions = 2; 
/* for each priority level, how may dfferent difficulty levels do we want? */ 


/* ====================================================================== */
/*                      Simple things                                     */
/* ====================================================================== */

set group_concat_max_len = 10240;
drop temporary table if exists simple_contact_table;
create temporary table simple_contact_table (
  contact_id int(10) not null,
  unique index(contact_id) );
drop temporary table if exists simple_bundle_table;
create temporary table simple_bundle_table (
  bundle_id int(10) not null,
  unique index(bundle_id) );
drop temporary table if exists simple_bundle_summary_table;
create temporary table simple_bundle_summary_table (
  bundle_id int(10) not null,
  summ text character set utf8,
  unique index(bundle_id) );


/**************************************************************************/
/**************************************************************************/
/***                                                                    ***/
/***                    qualified related objects                       ***/
/***                                                                    ***/
/**************************************************************************/
/**************************************************************************/

/* ====================================================================== */
/*               valid contacts                                           */
/* ====================================================================== */

drop table if exists valid_contacts; 
create table valid_contacts (
  id int(10), 
  unique index(id) ); 
insert into valid_contacts select id from civicrm_contact 
  where is_deleted != 1; 
  
  
/* ====================================================================== */
/*                relationships                                           */
/* ====================================================================== */

  
/* qualified relationship types */
drop table if exists qualified_relationship_types;
create table qualified_relationship_types (
  relationship_type_id int(10) not null,
  link_qualified int(1) not null,
  display_qualified int(1) not null,
  index(relationship_type_id),
  index(link_qualified),
  index(display_qualified) );
insert into qualified_relationship_types 
  select id, 0, 0
  from civicrm_relationship_type;

/* these relationship types are qualified for bundling */
update qualified_relationship_types
  set link_qualified = 1
  where relationship_type_id in (
    6,  /* head of household */
    7,  /* household member */
    15, /* umbrella organization */
    16, /* organization owner */
    17  /* equivalent contributor */
    );

/* These relationship types are qualified for displaying in the summary */
update qualified_relationship_types
  set display_qualified = 1
  where relationship_type_id in (
    1,  /* Child of */
    2,  /* Spouse of */
    3,  /* Sibling of */
    4,  /* Employee of */
    5,  /* Volunteer for */
    6,  /* Head of Household for */
    7,  /* Household Member of */
    8,  /* Case Coordinator is */
    10, /* Is Legally Guarded by */
    12, /* Has sent aid to */
    13, /* Step-child of */
    15, /* Umbrella organization is */
    16, /* Owns the organization */
    17, /* Equivalent Contributor */
    19, /* Friends with */
    22, /* Family relative of */
    25, /* somehow connected */
    27  /* data on other record */
    );

  
drop table if exists valid_relationships;
create table valid_relationships (
 id int(10), 
 unique index(id) ); 
insert into valid_relationships select rel.id
from civicrm_relationship rel
join valid_contacts c1 on c1.id = rel.contact_id_a 
join valid_contacts c2 on c2.id = rel.contact_id_b
where 
  is_active = 1 and 
  (start_date <= @now or start_date is null ) and
  (end_date   >  @now or end_date is null);


/* cache some info about related contacts */
drop temporary table if exists rels;
create temporary table rels (
  contact_id int unsigned not null,
  related_contact_id int unsigned not null,
  relationship_type_id int unsigned not null,
  index(contact_id),
  index(related_contact_id),
  index(relationship_type_id) );
insert into rels
select 
    contact_id_a   as contact_id, 
    contact_id_b   as related_contact_id,
    relationship_type_id
  from civicrm_relationship rel
  join valid_relationships v on v.id = rel.id
union distinct select 
    contact_id_b as contact_id, 
    contact_id_a as related_contact_id,
    relationship_type_id
  from civicrm_relationship rel
  join valid_relationships v on v.id = rel.id;

    

/* ====================================================================== */
/*                      contributions                                     */
/* ====================================================================== */

drop temporary table if exists valid_contribs;
create temporary table valid_contribs (
  id int(10), 
  contact_id int(10),
  unique index(id),
  index(contact_id) );
insert into valid_contribs select contrib.id, contact_id
from civicrm_contribution contrib
join valid_contacts v on v.id = contrib.contact_id
left join civicrm_value_contribution_custom_3 cust on 
  cust.entity_id = contrib.id
where 
  is_test != 1 and 
  contribution_status_id = 1 and 
  ( cust.matching_gift_company_92 = '' OR 
    cust.matching_gift_company_92 is null  ); 

  
  
/* ====================================================================== */
/*                      Phones                                            */
/* ====================================================================== */



/* short phone (for performance) */ 
drop temporary table if exists short_phones; 
create temporary table short_phones ( 
  phone_id int(10),
  contact_id int(10),
  location_type_id int(4),
  phone char(12) not null,
  unique index(phone_id), 
  index(contact_id),
  index(location_type_id),
  index(phone) ); 
insert into short_phones select 
    phone.id as phone_id, 
    contact_id, 
    location_type_id,
    substr(phone,1,12) as phone
  from civicrm_phone phone
  join valid_contacts v on v.id = phone.contact_id 
  where 
      contact_id > 0 and 
    /* must have at least 10 digits in there somewhere */
      phone.phone rlike '([0-9].*){10,}' and
    /* only go through the trouble if we're doing a PAT solicitation */ 
      @solicitation_type = 'PAT'; 

/* TODO inspect valid phones (by sorting) to see if there are any messy ones */ 

/* don't use phones present on organization records */ 
drop temporary table if exists work_phones;
create temporary table work_phones ( 
  phone char(12) not null,
  unique index(phone) ); 
insert into work_phones select distinct substr(phone.phone,1,12)
    from short_phones phone
    join civicrm_contact contact on contact.id = phone.contact_id
    where contact.contact_type = 'Organization';
delete sp 
  from short_phones sp
  join work_phones wp on wp.phone = sp.phone;


/* valid phone numbers */
drop table if exists valid_phones;
create table valid_phones (
  phone_id int(10) not null,
  contact_id int(10), 
  unique index(phone_id),
  index(contact_id) );
insert into valid_phones 
  select phone.phone_id, phone.contact_id 
  from short_phones phone
  left join civicrm_location_type location on 
    location.id = phone.location_type_id
  where
    /* can't be fake like 617-000-000 or 999-999-9999 */
      phone.phone not rlike concat('((0.?){7,})|((1.?){7,})|((2.?){7,})|',
        '((3.?){7,})|((4.?){7,})|((5.?){7,})|((6.?){7,})|((7.?){7,})|',
        '((8.?){7,})|((9.?){7,})') and 
    /* can't be fake like 617-555-1212 */
      phone.phone not rlike '[0-9]{3}.?555.?[0-9]{4}' and 
    /* can't be fake like 123-4567 */ 
      phone.phone not rlike '1[^0-9]?2[^0-9]?3[^0-9]?4[^0-9]?5[^0-9]?6[^0-9]?7'
      and 
    /* must not be international */
      phone.phone not rlike '^[^0-9]*\\+.*$' and
    /* must not be marked as "NoLongerValid" */
      location.name not like 'NoLongerValid%' and 
    /* can't be marked as a work phone location */ 
      location_type_id != 2;

/* all possible phone numbers for a contact */
drop table if exists contact_phones;
create table contact_phones (
  contact_id int(10) not null,
  phone_id int(10) not null,
  phone_compare char(12) not null,
  priority int(10),
  index(contact_id),
  index(phone_id),
  index(phone_compare),
  unique index(priority) );
insert into contact_phones
  select
      p.contact_id,
      p.id as phone_id,
      p.phone as phone_compare,
      is_primary*10000000+p.id as priority 
    from civicrm_phone p
    join valid_phones vp on vp.phone_id = p.id
    where p.contact_id > 0; 



/* ====================================================================== */
/*                      Addresses                                         */
/* ====================================================================== */

/* valid addresses */
drop temporary table if exists valid_addresses;
create temporary table valid_addresses (
  `id` int(10) unsigned NOT NULL,
  unique index(`id`) );
insert into valid_addresses
  select address.id 
  from civicrm_address address
  join valid_contacts v on v.id = address.contact_id
  join civicrm_state_province state on state.id = address.state_province_id
  left join civicrm_location_type location on location.id = address.location_type_id
  where
    contact_id > 0 and  
    length(address.street_address) > 3 and 
    length(city) >= 2 and 
    location.name not like '%NoLongerValid%' and
    state.country_id = 1228 /* USA addresses */ and 
    postal_code rlike '^[0-9][0-9][0-9][0-9][0-9].*$';


/* all possible addresses for a contact */
drop table if exists contact_addresses;
create table contact_addresses (
  contact_id int(10) not null,
  address_id int(10) not null,
  address_compare char(100) not null,
  priority int(10),
  index(contact_id),
  unique index(address_id),
  index(address_compare),
  unique index(priority));
insert into contact_addresses select
    a.contact_id,
    a.id as address_id,
    concat_ws('',postal_code,street_address,supplemental_address_1) 
      as address_compare,
    is_primary*10000000+a.id as priority
  from civicrm_address a
  join valid_addresses va on va.id = a.id;
  

/**************************************************************************/
/**************************************************************************/
/***                                                                    ***/
/***                    Exclusion                                       ***/
/***                                                                    ***/
/**************************************************************************/
/**************************************************************************/

drop table if exists exclude; 
drop table if exists exclude_situation; 
drop table if exists contact_bundle; 
drop table if exists exclude_strategy; 
create table exclude_strategy (
  name char(20), 
  importance int(2), 
  allows_remaining_contacts            int(1) not null,
  allows_remaining_contacts_when_house int(1) not null,
  name_appears_in_bundle               int(1) not null,
  allows_house_name_in_bundle          int(1) not null,
  force_name_in_summary                int(1) not null,
  unique index(name), 
  unique index(importance),
  index(allows_remaining_contacts), 
  index(allows_remaining_contacts_when_house), 
  index(name_appears_in_bundle),
  index(allows_house_name_in_bundle),
  index(force_name_in_summary) );
insert into exclude_strategy 
( name,       importance, 
                 allows_remaining_contacts, 
                    allows_remaining_contacts_when_house,
                       name_appears_in_bundle,
                          allows_house_name_in_bundle, 
                             force_name_in_summary ) values 
('eliminate' ,4, 0, 0, 1, 1, 0 ), 
('cloak'     ,3, 1, 0, 0, 0, 1 ),
('ignore'    ,2, 1, 1, 0, 1, 0 ),
('suspend'   ,1, 1, 1, 1, 1, 0 );


drop table if exists exclude; 
drop table if exists exclude_situation; 
create table exclude_situation ( 
  name         char(20), 
  dm_strategy  char(20),
  pat_strategy char(20),
  strategy     char(20),
  unique index(name), 
  index(dm_strategy),
  index(pat_strategy),
  index(strategy), 
  foreign key(strategy) references exclude_strategy (name) on delete cascade ); 
insert into exclude_situation 
(name, dm_strategy, pat_strategy ) values  
/* DO NOT EDIT THE DATA BELOW DIRECTLY.  
   This is a direct copy-paste from the ExclusionSituations spreadsheet */ 
('non-bmb-recurring','eliminate','eliminate'),
('non-bmb-pledge','eliminate','eliminate'),
('staff','eliminate','eliminate'),
('bat-rider','eliminate','eliminate'),
('matching-corp','eliminate','eliminate'),
('bmb-attendee-1','eliminate',NULL),
('board',NULL,'eliminate'),
('do-not-phone',NULL,'eliminate'),
('bat-company-sponsor',NULL,'eliminate'),
('missing-name','ignore','ignore'),
('too-young','ignore','ignore'),
('youth-participant','ignore','ignore'),
('youth-employee-ever','ignore','ignore'),
('organization',NULL,'ignore'),
('never-gave',NULL,'ignore'),
('missing-address','suspend',NULL),
('missing-phone',NULL,'suspend'),
('deceased','cloak','cloak'),
('do-not-mail','cloak',NULL);
/* DO NOT EDIT THE DATA ABOVE DIRECTLY */  


drop table if exists exclude; 
create table exclude (
  contact_id int(10), 
  situation char(20), 
  index(contact_id),
  index(situation),
  unique index(contact_id, situation), 
  foreign key(situation) references exclude_situation (name) on delete cascade); 
  

/* matching */ 
insert into exclude select id, 'matching-corp'
  from civicrm_contact where display_name like '%matching%'; 

/* recurring */ 
insert into exclude select distinct contact_id, 'non-bmb-recurring'
  from civicrm_contribution_recur
  where 
    cancel_date is null and 
    end_date is null and 
    is_test != 1 and 
    contribution_status_id = 5 and 
    financial_type_id != 19 /* MDBMB */ ;

/* pledge */ 
insert into exclude select distinct contact_id, 'non-bmb-pledge' 
  from civicrm_pledge
  where 
    cancel_date is null and 
    end_date is null and 
    is_test != 1 and 
    financial_type_id != 19 /* MDBMB */ ;

/* no name */ 
insert into exclude select id, 'missing-name'
  from civicrm_contact 
  where case contact_type
    when 'Individual' then 
      first_name is null or 
      last_name is null or 
      length(first_name) <= 0 or 
      length(last_name) <= 0
    when 'Household' then
      household_name is null or
      length(household_name) <= 10
    when 'Organization' then 
      organization_name is null or 
      length(organization_name) <= 1
  end;

/* deceased */ 
insert into exclude select id, 'deceased' from civicrm_contact where is_deceased = 1; 

/* no valid addresses */ 
insert into exclude select c.id, 'missing-address'
  from civicrm_contact c
  left join contact_addresses ca on ca.contact_id = c.id 
  where ca.contact_id is null;

/* do not mail */ 
insert into exclude select id, 'do-not-mail'
  from civicrm_contact where do_not_mail = 1; 

/* BAT rider */ 
insert into exclude select distinct part.contact_id, 'bat-rider'
  from civicrm_participant part 
  join civicrm_event e on e.id = part.event_id 
  join civicrm_participant_status_type stat on stat.id = part.status_id
  where 
    e.event_type_id = 1 and /* BAT */ 
    e.start_date between @now - interval 4 month and @now and 
    stat.is_counted = 1 and 
    part.role_id = 1 and /* atendee */ 
    part.is_test != 1;

/* BMB attendee, past 1 year */ 
insert into exclude select distinct part.contact_id, 'bmb-attendee-1'
  from civicrm_participant part 
  join civicrm_event e on e.id = part.event_id 
  join civicrm_participant_status_type stat on stat.id = part.status_id
  where 
    e.event_type_id = 17 and /* BMB */ 
    e.start_date between @now - interval 1 year and @now and 
    stat.is_counted = 1 and 
    part.role_id = 1 and /* atendee */ 
    part.is_test != 1;

/* BAT CS */ 
insert into exclude select distinct contact_id, 'bat-company-sponsor'
  from civicrm_contribution contrib
  where 
    financial_type_id = 10 /* BATCS */  and 
    receive_date between @now - interval 1 year and @now and 
    contribution_status_id = 1 /* completed */ and 
    is_test != 1;

/* no phone */ 
insert into exclude select id, 'missing-phone'
  from civicrm_contact contact
  left join valid_phones vp on vp.contact_id = contact.id
  where vp.contact_id is null; 

/* too young */ 
insert into exclude select id, 'too-young'
  from civicrm_contact
  where birth_date between @now - interval 18 year and '2009-01-01';
  /* this is 2009-01-01 because there is bad data after that from people using 
     the date widget to enter their birthdays and failing to enter the year */ 

/* organization */ 
insert into exclude select id, 'organization' 
  from civicrm_contact where contact_type = 'Organization'; 

/* never gave */ 
insert into exclude select contact.id, 'never-gave'
  from civicrm_contact contact 
  left join valid_contribs vc on vc.contact_id = contact.id 
  where vc.contact_id is null; 

/* staff */ 
insert into exclude select distinct contact_id, 'staff'
  from civicrm_group_contact gc 
  where gc.group_id in (19,20) and status = 'Added'; 

/* board */ 
insert into exclude select distinct contact_id, 'board' 
  from civicrm_group_contact gc 
  where gc.group_id = 16 and status = 'Added'; 

/* youth employees */ 
insert into exclude select distinct contact_id, 'youth-employee-ever'
  from civicrm_group_contact gc where gc.group_id = 27;  

/* youth participants */ 
insert into exclude select distinct part.contact_id, 'youth-participant'
  from civicrm_participant part 
  join civicrm_event e on e.id = part.event_id 
  where 
    e.event_type_id in (3,5,6,7,8,11,12) and /* youth progs */ 
    e.start_date between @now - interval 8 year and @now and 
    part.is_test != 1 and 
    part.role_id = 1;
  
/* do not phone */ 
insert into exclude select id, 'do-not-phone'
  from civicrm_contact where do_not_phone = 1; 

/* only use exclusions for the type of search we're doing */ 
update exclude_situation set strategy =  dm_strategy where @solicitation_type = 'DM'; 
update exclude_situation set strategy = pat_strategy where @solicitation_type = 'PAT'; 
delete from exclude_situation where strategy is null; 
/* because of the foreign key constraint on the `exclude` table, the above drop 
query will also drop rows from the `exclude` table */ 




/**************************************************************************/
/**************************************************************************/
/***                                                                    ***/
/***                    Bundling                                        ***/
/***                                                                    ***/
/**************************************************************************/
/**************************************************************************/

  
/* ====================================================================== */
/*  prepare data to hand off to network coagulation                       */
/* ====================================================================== */

/* all the contacts up for consideration */
drop table if exists all_contacts; 
create table all_contacts (
  contact_id int(10),
  unique index(contact_id) );
insert into all_contacts select id from valid_contacts;

/* which contacts are connected to one another */
drop table if exists connected_contacts;
create table connected_contacts ( 
  contact_id_a int(10),
  contact_id_b int(10),
  reason char(50),
  index(contact_id_a),
  index(contact_id_b),
  index(reason) );

/* relationship connections */
insert into connected_contacts
  select
    rels.contact_id as contact_id_a,
    rels.related_contact_id as contact_id_b,
    'related' as reason
  from rels
  join qualified_relationship_types qrt
    on qrt.relationship_type_id = rels.relationship_type_id and
      link_qualified = 1;

/* phone number connections */
insert into connected_contacts
  select 
    p1.contact_id as contact_id_a,
    p2.contact_id as contact_id_b,
    'phones' as reason
  from contact_phones p1
  join contact_phones p2 on 
    p2.phone_compare = p1.phone_compare and 
    p2.contact_id > p1.contact_id
  where @solicitation_type = 'PAT';


/* address connections * 
(commented out because it was too hard to get this to produce good results. Lots
of contacts were getting linked that shouldn't be). 
insert into connected_contacts
  select 
    a1.contact_id as contact_id_a,
    a2.contact_id as contact_id_b,
    'addresses' as reason
  from contact_addresses a1
  join contact_addresses a2 on a2.address_compare = a1.address_compare
  join civicrm_contact c1 on c1.id = a1.contact_id
  join civicrm_contact c2 on c2.id = a2.contact_id
  where 
    a2.contact_id > a1.contact_id and 
    c1.last_name = c2.last_name and 
    @solicitation_type = 'DM';

  
  
/* ====================================================================== */
/*                      perform coagulation                               */
/* ====================================================================== */

/* Network coagulation needs:

   (1) a table called `connected_contacts` with two columns contact_id_a and 
       contact_id_b that are connected to one another.    
   
   (2) a table called `all_contacts` that with one column contact_id that 
       contains all the contacts up for consideration. 
   
   Network coagulation will sanitize this data to make sure it's properly 
   ordered and not redundant. Then network coagulation will do its fancy work
   to produce the `graph_node` and `bundle` tables. */
   
/* insert edges */
drop table if exists graph_edge;
create table graph_edge (
  contact_id_a int(10) not null,
  contact_id_b int(10) not null,
  index(contact_id_a),
  index(contact_id_b),
  unique index(contact_id_a,contact_id_b) );
insert into graph_edge
  select distinct
    least(contact_id_a,contact_id_b),
    greatest(contact_id_a,contact_id_b)
  from connected_contacts
  where contact_id_a != contact_id_b;

/* cache node edges in both directions */
drop table if exists node_edge_bidirectional;
create table node_edge_bidirectional (
  contact_id int(10) not null,
  connected_contact_id int(10) not null,
  index(contact_id),
  index(connected_contact_id),
  unique index(contact_id,connected_contact_id) );
insert into node_edge_bidirectional
  select 
      contact_id_a as contact_id,
      contact_id_b as connected_contact_id
    from graph_edge
  union distinct select 
      contact_id_b as node_id, 
      contact_id_a as connected_node_id
    from graph_edge;

/* insert nodes */
drop table if exists graph_node;
create table graph_node (
  contact_id int(10),
  network_min_contact_id int(10), /* the lowest contact id in this node's net */
  unique index(contact_id),
  index(network_min_contact_id) );
insert into graph_node
  select distinct
      contact_id,
      contact_id
    from node_edge_bidirectional
  union distinct select 
      contact_id,
      contact_id
    from all_contacts;

/* group all connected networks */ 
drop procedure if exists coagulate;
delimiter |
create procedure coagulate()
begin
  set @row_count = 1; 
  while @row_count > 0 do
    
    update graph_node
    join (
      select 
        node.contact_id,
        min(related_node.network_min_contact_id) as min_id
      from graph_node node
      join node_edge_bidirectional edge on 
        edge.contact_id = node.contact_id
      join graph_node related_node on 
        related_node.contact_id = edge.connected_contact_id
      group by node.contact_id
      having min_id < node.contact_id
      ) net
      on net.contact_id = graph_node.contact_id
    set graph_node.network_min_contact_id = net.min_id
    where graph_node.network_min_contact_id != net.min_id;
    
    set @row_count = row_count(); 
    
  end while;
end|
delimiter ;
/* */
call coagulate();

/* inspect networks *
select
  network_min_contact_id,
  count(distinct contact_id) as num,
  group_concat(distinct contact_id) as contacts
from graph_node
group by network_min_contact_id
having num > 1
order by num desc;  /**/ 


/* bundle */
drop table if exists bundle;
create table bundle (
  id int(10) not null,
  quant_total      int(3) comment "how many contacts are in the bundle",
  contact_types    char(3) comment "first letters of Individual, Household, Organization concatenated to show which tupes of contacts are in the bundle",
  yafl             double comment "years after first log", 
  aa_baseline      decimal (8,2) comment "ask amount if there are no contributions",
  aa_mean          decimal(8,2) comment "ask amount using the mean model",
  aa_rate          decimal(8,2) comment "ask amount using the rate model",
  aa_meat          decimal(8,2) comment "ask amount using a combination of the results from the mean model and the rate model", 
  aa_sub           decimal(8,2) comment "dollar amount to subtract from the ask amount due to recency subtraction",
  aa_expected      decimal(8,2) comment "amount we'd expect the donor to give. This get's stretched slightly to form the raw ask amount",
  aa_raw           decimal(8,2) comment "final ask amount before any rounding",
  aa_rf            decimal(8,2) comment "ask amount rounding floor -- used only as an intermediate value when calculating aa_round",
  aa_round         decimal(8,2) comment "rounded ask amount to a nice looking number. This is the final ask amount printed on call sheet",
  aa_monthly       decimal(8,2) comment "a reasonable monthly donation to ask for",
  lh_dedication    double comment "likelihood dedication",
  lh_readiness     double comment "likelihood readiness",
  likelihood       double comment "final likelihood", 
  priority         double comment "priority",
  difficulty       double comment "difficulty", 
  list_order       int(10) comment "This bundle's position in a list of all bundles sorted with highest priority first",
  is_excluded      int(1) not null default 0 comment "",
  is_fresh         int(1) not null default 0 comment "fresh means they've never given before",
  is_chosen        int(1) not null default 0 comment "final yes/no on whether we want to solicit this bundle",
  priority_level   char(2) comment "A letter-based level to represent priority",
  difficulty_level int(2) comment "A number-based leven to represent difficulty",
  pile             char(3) comment "The priority and difficulty put into one short code",
  unique index(id),
  index(quant_total),
  index(contact_types),
  index(yafl),
  index(aa_baseline),
  index(aa_mean),
  index(aa_rate),
  index(aa_meat), 
  index(aa_sub),
  index(aa_expected),
  index(aa_raw),
  index(aa_rf),
  index(aa_round),
  index(lh_dedication),
  index(lh_readiness),
  index(likelihood),
  index(priority),
  index(difficulty),
  unique index(list_order), 
  index(is_excluded),
  index(is_fresh),
  index(is_chosen),
  index(priority_level),
  index(difficulty_level),
  index(pile) );
insert into bundle (id, quant_total)
  select
    graph_node.network_min_contact_id as id,
    count(distinct graph_node.contact_id) as quant
  from graph_node
  group by graph_node.network_min_contact_id;


drop table if exists contact_bundle; 
create table contact_bundle (
  contact_id int(10), 
  bundle_id int(10), 
  exclude_strategy char(20),
  exclude_this int(1),
  exclude_whole int(1),
  unique index(contact_id), 
  index(bundle_id),
  index(exclude_this),
  index(exclude_whole), 
  index(exclude_strategy),
  foreign key(exclude_strategy) 
    references exclude_strategy (name) on delete cascade ); 
insert into contact_bundle (contact_id, bundle_id) select 
  contact_id,
  network_min_contact_id
from graph_node;

drop temporary table if exists bundle_contact_types;
create temporary table bundle_contact_types (
  bundle_id int(10), 
  contact_types char(3), 
  unique index(bundle_id) ); 
insert into bundle_contact_types select 
    bundle_id,
    group_concat( 
      distinct substr(contact_type,1,1) 
      order by contact_type
      separator ''
    ) as contact_types
  from contact_bundle cb
  join civicrm_contact contact on contact.id = cb.contact_id 
  group by bundle_id;

update bundle 
join bundle_contact_types bct on bct.bundle_id = bundle.id 
set bundle.contact_types = bct.contact_types; 


/* ====================================================================== */
/*        exclusion, single contact level                                 */
/* ====================================================================== */

drop temporary table if exists contact_exclude; 
create temporary table contact_exclude( 
  contact_id int(10), 
  strategy_importance int(2), 
  unique index(contact_id),
  index(strategy_importance) ); 
insert into contact_exclude select 
    contact_id, 
    max(strat.importance)
  from exclude
  join exclude_situation sit on sit.name = exclude.situation
  join exclude_strategy strat on strat.name = sit.strategy
  group by contact_id; 

update contact_bundle cb
join civicrm_contact contact on contact.id = cb.contact_id
left join contact_exclude x on x.contact_id = cb.contact_id 
left join exclude_strategy strat on strat.importance = x.strategy_importance
set 
  cb.exclude_strategy = strat.name, 
  exclude_this = if(strat.name is not null, 1, 0),
  exclude_whole = if(
    strat.allows_remaining_contacts = 0 or 
    ( contact.contact_type = 'Household' and 
      strat.allows_remaining_contacts_when_house = 0 ), 
    1, 0 );



/* ====================================================================== */
/*                exclusion, bundle level                                 */
/* ====================================================================== */

drop temporary table if exists bundle_exclude; 
create temporary table bundle_exclude (
  bundle_id int(10), 
  unique index(bundle_id) ); 
insert into bundle_exclude select bundle_id 
  from contact_bundle 
  group by bundle_id 
  having min(exclude_this) = 1 or max(exclude_whole) = 1;

update bundle b
join bundle_exclude x on x.bundle_id = b.id 
set is_excluded = 1; 



/**************************************************************************/
/**************************************************************************/
/***                                                                    ***/
/***                    Contribution worksheet                          ***/
/***                                                                    ***/
/**************************************************************************/
/**************************************************************************/


drop temporary table if exists financial_type_weights;
create temporary table financial_type_weights (

  financial_type_id int(4),
  /* financial type, referenced in documentation below as the variable "T" */
  
  solicitation_type char(20), 
  /* what type of solicitation are we performing, as a whole. 'DM' or 'PAT'? */ 
  
  ask_amount_multiplier decimal(3,2),
  /* Scale the expected contribution by this amount.
     1 = expect them to give this amount
     0.5 = expect them to give only half this amount */ 
  
  ask_amount_weight decimal(3,2),
  /* weight the existing data by this amount. 
     1 = very relevant 
     0 = irrelevant */

  ask_amount_subtraction decimal(3,2),
  /* if the contribution is recent, how much do we want to subtract 
     1 = subtract the whole thing
     0 = subtract none */
  
  likelihood_optimism decimal(3,2),
  /* When receiving a contribution of type T, how optimistic are we that 
     we will subsequently receive a contribution of the type that we're 
     soliciting? 
     1 = completely optimistic
     0 = not at all optimistic */ 
  
  likelihood_resilience decimal(3,2),
  /* Let us first define an "affirmative event" as the date of most recent 
     desired contribution (e.g. for Phone-A-Thon it would be PAT or UD), or 
     if no such contribution has been made, we use the date created. So now, if
     we have NOT had an affirmative event recently, and then we receive a 
     contribution of type T, what do we do?...
     0 resilience = we'll basically give up and not expect to receive the
       contribution that we're soliciting
     1 resilience = we'll calculate the likelihood just as we would if an 
       affirmative event happened recently */ 
  
  likelihood_immediate_readiness decimal(3,2),
  /* How ready to give again will the donor be immediately after making
     a contribution of type T? 
     0 = not at all ready
     1 = completely ready */ 

  likelihood_readiness_delay decimal(3,2), /* (in years) */ 
  /* After a contribution of type T, how long will it take for the donor to
     become completely ready to give a contribution of the type that we're 
     soliciting? 
     0 = ready right away
     1 = ready in ONE YEAR */ 

  affirmative_event int(1), 
  /* will a contribution of type T qualify as an affiramtive event? */
  
  display_qualified int(1), 
  /* do we want to show this contrib in the print out contrib summary? */
  
  index(affirmative_event), 
  index(display_qualified) );
insert into financial_type_weights values /*
 financial type ID
   || Search type
   ||      || Ask amount multiplier
   ||      ||    || Ask amount weight 
   ||      ||    ||    || Ask amount subtraction   
   ||      ||    ||    ||    || Likelihood optimism
   ||      ||    ||    ||    ||    || Likelihood resilience 
   ||      ||    ||    ||    ||    ||    || Likelihood immediate readiness
   ||      ||    ||    ||    ||    ||    ||    || Likelihood readiness delay (years)
   ||      ||    ||    ||    ||    ||    ||    ||    || Is an affirmative event
   ||      ||    ||    ||    ||    ||    ||    ||    ||   || Display on call sheet? */

/* vanilla fundraising */ 
( 5, 'PAT',  1.00, 0.85, 1.00, 0.80, 0.30, 0.00, 0.40,  0,   1), /* DM */
( 5, 'DM',   1.00, 1.00, 1.00, 1.00, 1.00, 0.00, 0.51,  1,   0), /* DM */
( 9, 'PAT',  1.00, 1.00, 1.00, 1.00, 1.00, 0.00, 0.40,  1,   1), /* PAT */
( 9, 'DM',   1.00, 0.85, 1.00, 0.85, 1.00, 0.00, 0.35,  1,   0), /* PAT */
( 1, 'PAT',  1.00, 0.80, 1.00, 0.85, 1.00, 0.00, 0.40,  1,   1), /* UD */
( 1, 'DM',   1.00, 0.80, 1.00, 0.95, 1.00, 0.00, 0.51,  1,   0), /* UD */
(24, 'PAT',  1.00, 0.90, 1.00, 0.85, 0.60, 0.00, 0.40,  0,   1), /* EM */
(24, 'DM',   1.00, 0.90, 1.00, 0.85, 1.00, 0.00, 0.30,  1,   0), /* EM */
( 7, 'PAT',  1.00, 0.60, 1.00, 0.40, 0.70, 0.00, 0.40,  0,   1), /* MD */
( 7, 'DM',   1.00, 0.60, 1.00, 0.40, 0.70, 0.00, 0.30,  1,   0), /* MD */
(19, 'PAT',  1.00, 0.70, 1.00, 0.50, 0.65, 0.00, 0.30,  0,   1), /* MDBMB */
(19, 'DM',   1.00, 0.70, 1.00, 0.60, 0.65, 0.00, 0.25,  1,   0), /* MDBMB */

/* solicited through third party */ 
( 2, 'PAT',  0.60, 0.20, 0.60, 0.25, 0.05, 0.30, 0.30,  0,   1), /* BATRS */
( 2, 'DM',   0.60, 0.20, 0.60, 0.65, 0.15, 0.70, 0.10,  0,   0), /* BATRS */
(27, 'PAT',  0.40, 0.20, 0.80, 0.15, 0.15, 0.40, 0.30,  0,   1), /* TPF */
(27, 'DM',   0.40, 0.20, 0.80, 0.30, 0.15, 0.70, 0.10,  0,   0), /* TPF */
(28, 'PAT',  0.70, 0.30, 0.80, 0.60, 0.20, 0.30, 0.30,  0,   1), /* GIFT */
(28, 'DM',   0.90, 0.30, 0.80, 0.70, 0.20, 0.40, 0.30,  1,   0), /* GIFT */

/* Misc solicited */ 
( 3, 'PAT',  1.00, 0.02, 0.80, 0.60, 0.15, 1.00, 0.00,  0,   1), /* BDF */
( 3, 'DM',   1.50, 0.02, 0.80, 0.70, 0.15, 1.00, 0.00,  0,   0), /* BDF */
( 4, 'PAT',  0.80, 0.08, 1.00, 0.20, 0.00, 0.50, 0.30,  0,   1), /* BLDG */
( 4, 'DM',   0.80, 0.08, 1.00, 0.20, 0.00, 0.50, 0.20,  1,   0), /* BLDG */
(15, 'PAT',  1.00, 0.40, 1.00, 0.50, 0.50, 0.50, 0.10,  0,   1), /* OLD */
(15, 'DM',   1.00, 0.40, 1.00, 0.80, 0.50, 0.50, 0.10,  0,   0), /* OLD */
(22, 'PAT',  1.00, 0.50, 1.00, 0.60, 0.20, 0.30, 0.20,  0,   0), /* BATER */
(22, 'DM',   1.00, 0.50, 1.00, 0.60, 0.20, 0.30, 0.20,  0,   0), /* BATER */
(13, 'PAT',  1.00, 0.05, 0.90, 0.40, 0.60, 0.20, 0.30,  0,   1), /* EVD */
(13, 'DM',   1.00, 0.05, 0.70, 0.40, 0.60, 0.30, 0.20,  0,   0), /* EVD */

/* work-related */ 
( 8, 'PAT',  1.00, 0.10, 1.00, 0.15, 0.10, 0.50, 0.30,  0,   1), /* PD */
( 8, 'DM',   1.00, 0.10, 1.00, 0.15, 0.10, 0.50, 0.15,  0,   0), /* PD */
(25, 'PAT',  1.00, 0.10, 0.50, 0.00, 0.00, 1.00, 0.00,  0,   1), /* CM */
(25, 'DM',   1.00, 0.10, 0.50, 0.00, 0.00, 1.00, 0.00,  0,   0), /* CM */

/* where you get something in return */ 
(17, 'PAT',  1.00, 0.05, 0.10, 0.10, 0.00, 1.00, 0.00,  0,   0), /* AR */
(17, 'DM',   1.00, 0.05, 0.00, 0.10, 0.00, 1.00, 0.00,  0,   0), /* AR */
(26, 'PAT',  1.20, 0.05, 0.60, 0.50, 0.10, 0.80, 0.15,  0,   1), /* MEM */
(26, 'DM',   1.50, 0.05, 0.60, 0.50, 0.10, 0.90, 0.10,  0,   0), /* MEM */
(14, 'PAT',  1.00, 0.05, 0.10, 0.35, 0.50, 0.70, 0.20,  0,   1), /* EVF */
(14, 'DM',   1.00, 0.05, 0.05, 0.35, 0.50, 0.80, 0.10,  0,   0), /* EVF */
(10, 'PAT',  1.00, 0.05, 0.00, 0.00, 0.00, 0.90, 0.30,  0,   0), /* BATCS */
(10, 'DM',   1.00, 0.05, 0.00, 0.00, 0.00, 1.00, 0.00,  0,   0), /* BATCS */

/* designated */ 
(20, 'PAT',  1.00, 0.60, 1.00, 0.65, 0.30, 0.20, 0.30,  0,   1), /* OMWOMB */
(20, 'DM',   1.00, 0.60, 1.00, 0.65, 0.30, 0.20, 0.20,  1,   0), /* OMWOMB */
(21, 'PAT',  1.00, 0.60, 1.00, 0.65, 0.30, 0.20, 0.30,  0,   1), /* WMOTW */
(21, 'DM',   1.00, 0.60, 1.00, 0.65, 0.30, 0.20, 0.20,  1,   0), /* WMOTW */
(23, 'PAT',  1.00, 0.60, 1.00, 0.65, 0.30, 0.20, 0.30,  0,   1), /* UG */
(23, 'DM',   1.00, 0.60, 1.00, 0.65, 0.30, 0.20, 0.20,  1,   0), /* UG */
(29, 'PAT',  1.00, 0.60, 1.00, 0.65, 0.30, 0.20, 0.30,  0,   1), /* BICI */
(29, 'DM',   1.00, 0.60, 1.00, 0.65, 0.30, 0.20, 0.20,  1,   0), /* BICI */
(30, 'PAT',  1.00, 0.60, 1.00, 0.65, 0.30, 0.20, 0.30,  0,   1), /* AB */
(30, 'DM',   1.00, 0.60, 1.00, 0.65, 0.30, 0.20, 0.20,  1,   0), /* AB */
(34, 'PAT',  1.00, 0.60, 1.00, 0.65, 0.30, 0.20, 0.30,  0,   1), /* YBS */
(34, 'DM',   1.00, 0.60, 1.00, 0.65, 0.30, 0.20, 0.20,  1,   0), /* YBS */

/* irrelevant */ 
( 6, 'PAT',  1.00, 0.00, 0.00, 0.00, 0.00, 1.00, 0.00,  0,   0), /* GRANT */
( 6, 'DM',   1.00, 0.00, 0.00, 0.00, 0.00, 1.00, 0.00,  0,   0), /* GRANT */
(16, 'PAT',  1.00, 0.00, 0.00, 0.00, 0.00, 1.00, 0.00,  0,   0), /* PF*/
(16, 'DM',   1.00, 0.00, 0.00, 0.00, 0.00, 1.00, 0.00,  0,   0), /* PF*/
(18, 'PAT',  1.00, 0.00, 0.00, 0.00, 0.00, 1.00, 0.00,  0,   0), /* PUR */
(18, 'DM',   1.00, 0.00, 0.00, 0.00, 0.00, 1.00, 0.00,  0,   0), /* PUR */
(11, 'PAT',  1.00, 0.00, 0.00, 0.20, 0.10, 1.00, 0.00,  0,   0), /* BATRF */
(11, 'DM',   1.00, 0.00, 0.00, 0.20, 0.10, 1.00, 0.00,  0,   0), /* BATRF */
(12, 'PAT',  1.00, 0.00, 0.00, 0.00, 0.00, 1.00, 0.00,  0,   0), /* GRF */
(12, 'DM',   1.00, 0.00, 0.00, 0.00, 0.00, 1.00, 0.00,  0,   0); /* GRF */



/* We only care about the values for this particular solicitation type */ 
delete from financial_type_weights
where solicitation_type != @solicitation_type; 

/* Now that we've deleted the values for other solicitation types, we can go
  ahead and uniquely index the financial type id to improve performance */ 
alter table financial_type_weights add unique(financial_type_id); 


/**************************************************************************/
/**************************************************************************/
/***                                                                    ***/
/***                    Contribution worksheet                          ***/
/***                                                                    ***/
/**************************************************************************/
/**************************************************************************/

/* a place to store intermediate values for each contribution while computing 
   the ask amount and likelihood */

   
drop table if exists contrib_worksheet; 
create table contrib_worksheet (
      id int(10) auto_increment, 
      cid int(10) comment "contribution id",
      bundle_id int(10),
      amt  decimal(8,2) comment "amount",
      rta  double       comment "running total amount",
      subw decimal(6,4) comment "subtraction weight",
      sub  decimal(8,2) comment "amount to subtract from ask amount due to recency",
      ybn  decimal(6,4) comment "years before now",
      yaf  decimal(6,4) comment "years after first",
      mul  decimal(6,4) comment "ask amount multiplier",
      ws   decimal(6,4) comment "ask amount weight, simple",
      op   decimal(3,2) comment "optimism of the current contribution",
      rs   decimal(3,2) comment "resilience of the current contribution",
      rdi  decimal(3,2) comment "immediate readiness of the current contribution",
      rdd  decimal(3,2) comment "readiness delay of the current contribution",
      ta   decimal(6,4) comment "years between the time of the current contribution and the most recently prior affirmative event",
      tc   decimal(6,4) comment "years between the time of the current contribution and the most recently prior contribution",
      ti   decimal(6,4) comment "years between the time of the current contribution and the first (initial) log entry",
      wf   double comment "full ask amount weight (considering simple weight and ybn)",
      rb   double comment "reliability at the time of the current contribution",
      dbr  double comment "dedication immediately before the current contribution, if rb=1",
      dbu  double comment "dedication immediately before the current contribution, if rb=0",
      db   double comment "dedication immediately before the current contribution",
      da   double comment "dedication immediately after the current contribution", 
      bs   double comment "bolster strength of the current contribution and its point in time",
      rds  double comment "specific readiness of this contribution and its point in time",
      crds double comment "cumulative readieness (product of all readieness values)", 
      is_first int(1) not null default 0 comment "true if this is the first contribution for the bundle", 
      unique index(id), 
      index(bundle_id),
      index(ybn) ); 
insert into contrib_worksheet (
    cid,
    bundle_id,
    amt,
    subw,
    mul,
    ws,
    op, 
    rs,
    rdi,
    rdd,
    ybn
  ) select
  contrib.id as cid,
  cb.bundle_id as bundle_id,
  contrib.total_amount as amt,
  ctw.ask_amount_subtraction as subw,
  ctw.ask_amount_multiplier as mul,
  ctw.ask_amount_weight as ws,
  ctw.likelihood_optimism as op,
  ctw.likelihood_resilience as rs,
  ctw.likelihood_immediate_readiness as rdi,
  ctw.likelihood_readiness_delay as rdd,
  datediff(@now,contrib.receive_date)/365.0 as ybn
from civicrm_contribution contrib
join valid_contribs vc on vc.id = contrib.id
join contact_bundle cb on cb.contact_id = contrib.contact_id
join financial_type_weights ctw on 
  ctw.financial_type_id = coalesce(contrib.financial_type_id,15)
having ybn > 0.0
union (
  select 
    null as cid,
    id as bundle_id,
    null as amt,
    null as subw,
    null as mul,
    null as ws,
    null as op,
    null as rs,
    null as rdi,
    null as rdd, 
    0.0 as ybn
  from bundle 
  )
order by bundle_id, ybn desc;



/* ====================================================================== */
/*                      is_first, tc, yaf, rta                            */
/* ====================================================================== */

set @prta = 0.0; 
set @pbundle_id = 0; 
set @is_first = 0; 
set @pybn = 0.0; 
set @pyaf = 0.0; 
update contrib_worksheet 
set 
  is_first = @is_first := if(@pbundle_id != bundle_id, 1, 0 ),
  
  /* time since the last contribution */ 
  tc = @tc := if(@is_first, null, @pybn - ybn ),
  
  /* years after the first contribution */ 
  yaf = @pyaf := if(@is_first, 0, @pyaf + @tc ), 
  
  /* running total amount */ 
  rta = @prta := if(@is_first, 0, @prta) + coalesce(amt,0) * coalesce(mul,1),
  
  bundle_id = @pbundle_id := bundle_id,
  ybn = @pybn := ybn; 



/* ====================================================================== */
/*              time since first log, and initial dedication value        */
/* ====================================================================== */

drop temporary table if exists first_log; 
create temporary table first_log ( 
  bundle_id int(10), 
  ybn double, 
  unique index(bundle_id) ); 
insert into first_log select 
    bundle.id, 
    datediff( @now, min(logg.modified_date) )/365.0 as ybn
  from bundle
  join contact_bundle cb on cb.bundle_id = bundle.id
  join civicrm_log logg on 
    logg.entity_table = 'civicrm_contact' and 
    logg.entity_id = cb.contact_id
  group by bundle.id
  having ybn > 0.0;

update bundle 
join first_log on first_log.bundle_id = bundle.id 
set bundle.yafl = first_log.ybn;

/* ti -- time since first log */ 
update contrib_worksheet cw
join bundle on bundle.id = cw.bundle_id
set cw.ti = coalesce(greatest(bundle.yafl - cw.ybn, 0),0);


/* dedication before first contribution: decay vs. time-since-first-log */ 
set @fdbfdec = case @solicitation_type when 'DM' then 3 when 'PAT' then 3 end; 

/* dedication before first contribution: decay sharpness */ 
set @fdbfshp = case @solicitation_type when 'DM' then 2.3 when 'PAT' then 2.3 end; 

/* dedication before first contribution: max value (immediately after first log) */ 
set @fdbfmax = case @solicitation_type when 'DM' then 0.3 when 'PAT' then 0.2 end; 

/* initial dedication value */ 
update contrib_worksheet cw
set db = @fdbfmax / (1 + pow(ti/@fdbfdec,@fdbfshp) )
where is_first = 1; 



/* ====================================================================== */
/*                        wf                                              */
/* ====================================================================== */


/* weight decay rate */ 
set @fwdr = case @solicitation_type when 'DM' then 0.22 when 'PAT' then 0.22 end; 

/* weight decay sharpness */ 
set @fwds = case @solicitation_type when 'DM' then 4.2 when 'PAT' then 4.2 end; 

update contrib_worksheet c
set wf = ws/(1 + pow(@fwdr*ybn,@fwds) );



/**************************************************************************/
/**************************************************************************/
/***                                                                    ***/
/***                    Ask amount                                      ***/
/***                                                                    ***/
/**************************************************************************/
/**************************************************************************/



/* ====================================================================== */
/*                      baseline                                          */
/* ====================================================================== */

/* baseline decay time */ 
set @fbldec = case @solicitation_type when 'DM' then 2.5 when 'PAT' then 4 end; 

/* baseline decay sharpness */ 
set @fblshp = case @solicitation_type when 'DM' then 3.4 when 'PAT' then 2 end; 

/* baseline maxiumum */ 
set @fblmax = case @solicitation_type when 'DM' then 25 when 'PAT' then 0 end; 

update bundle
set aa_baseline =  @fblmax/(1 + pow(yafl/@fbldec,@fblshp) ); 



/* ====================================================================== */
/*                      Rate (regression)                                 */
/* ====================================================================== */



/* Which points are worth analyzing through regression? Only the ones with 
  significant weight that correspond to actual contributions . */ 

drop temporary table if exists influential_points; 
create temporary table influential_points (
  bundle_id int(10), 
  x double comment "position in time, relative to now",
  dx float comment "difference in position in time between contribs",
  w float comment "contribution weight",
  index(bundle_id) ); 
insert into influential_points (bundle_id, x, w) select
  bundle_id, 
  -ybn,
  wf
from contrib_worksheet cw
where 
  wf > 0.1 and 
  cid is not null;
  
set @pbundle_id = 0; 
set @px = 0.0; 
update influential_points 
set 
  dx = if(bundle_id = @pbundle_id, x - @px, null ), 
  bundle_id = @pbundle_id := bundle_id, 
  x = @px := x; 

  
  
/* rate qualification:
   Some bundles only have one contribution. Obviously for these we don't want to
   perform any regression at all. Some have contributions every month for the 
   last year. For these we want to make sure to perform a regression AND to 
   trust that regression over the mean model. And then some budles are in 
   between these two cases. The rate qualification assigns a qualification value
   to each bundle from 0 to 1 for exactly HOW qualified this bundle is to use
   the rate model for the ask amount */ 
   
drop temporary table if exists bundle_rate_qualification; 
create temporary table bundle_rate_qualification (
  bundle_id int(10), 
  point_count int(4) comment "the number of influential points (contributions) in this bundle",
  point_count_factor float unsigned comment "point_count squeezed to be within 0 and 1",
  time_range float unsigned comment "the total time window (in years) between the first contrib and the last contrib",
  time_range_factor float unsigned comment "the time range squeezed to be within 0 and 1",
  significant_intervals float unsigned comment "the number of intervals between contributions where the interval time is at least 25 days",
  significant_intervals_factor float unsigned comment "significant_intervals sqeezed to be within 0 and 1", 
  contrib_weight float unsigned comment "the collective weight of all contributions within this bundle",
  contrib_weight_factor float unsigned comment "contrib_weight sqeezed to be within 0 and 1",
  qualification float unsigned comment "how qualified this bundle is to use the rate model for the ask amount. 0 means don't use rate at all. 1 means use rate completely.",
  to_regress int(1) comment "do we want to even perform regression on this bundle?",
  unique index(bundle_id) ); 
insert into bundle_rate_qualification (
    bundle_id, 
    point_count,
    time_range, 
    significant_intervals,
    contrib_weight ) 
  select 
    bundle_id, 
    count(*), 
    max(x)-min(x), 
    sum(if(dx > 25/365, 1, 0)),
    sum(w*w)
  from influential_points
  group by bundle_id; 
  
set @frqpce = 4; /* rate qualification point count factor extent */ 
set @frqpcs = 2.5; /* rate qualification point count factor sharpness */ 
update bundle_rate_qualification set 
  point_count_factor = 1 - 1/(1 + pow(point_count/@frqpce,@frqpcs) );

set @frqtre = 1; /* rate qualification time range factor extent */ 
set @frqtrs = 3.3; /* rate qualification time range factor sharpness */ 
update bundle_rate_qualification set 
  time_range_factor = 1 - 1/(1 + pow(time_range/@frqtre,@frqtrs) );

set @frqsie = 5; /* rate qualification significant intervals factor extent */ 
set @frqsis = 3; /* rate qualification significant intervals factor sharpness */ 
update bundle_rate_qualification set 
  significant_intervals_factor = 
    1 - 1/(1 + pow(significant_intervals/@frqsie,@frqsis) );

set @frqcwe = 3.5; /* rate qualification contrib weight factor extent */ 
set @frqcws = 2; /* rate qualification contrib weight factor sharpness */ 
update bundle_rate_qualification set 
  contrib_weight_factor = 1 - 1/(1 + pow(contrib_weight/@frqcwe,@frqcws) );

update bundle_rate_qualification set qualification = pow(
  point_count_factor *
  time_range_factor * 
  significant_intervals_factor *
  contrib_weight_factor, 1/4); 
  
/* choose which ones to bother performing the regression on */ 
update bundle_rate_qualification set to_regress = 1 where 
    point_count >= 4 and 
    time_range >= 1 and 
    significant_intervals >= 3;
update bundle_rate_qualification set to_regress = 0 where to_regress is null; 



/* actual points to regress */   
drop temporary table if exists regression_data; 
create temporary table regression_data (
  bundle_id int(10), 
  x1 double,
  x2 double,
  y  double,
  w  double comment "weight",
  index(bundle_id) ); 
insert into regression_data select 
  cw.bundle_id, 
  -ybn    as x1,
  ybn*ybn as x2,
  rta     as y,
  wf      as w
from contrib_worksheet cw 
join bundle_rate_qualification q on 
  q.bundle_id = cw.bundle_id and 
  q.to_regress = 1
where
  cid is not null and 
  wf > 0;

drop temporary table if exists indicator_time; 
create temporary table indicator_time (
  bundle_id int(10), 
  t double,
  unique index(bundle_id) ); 
insert into indicator_time select 
  bundle_id, 
  least(max(x) + 1, 0) as t
from influential_points
group by bundle_id; 

drop temporary table if exists regression; 
create temporary table regression ( 
  bundle_id int(10), 
  sx0x0 double,
  sx0x1 double,
  sx0x2 double,
  sx0y  double,
  sx1x1 double,
  sx1x2 double,
  sx1y  double,
  sx2x2 double,
  sx2y  double,
  det1  double,
  det2  double, 
  o1b1  double,
  o1b2  double,
  o2b1  double,
  o2b2  double,
  o2b3  double,
  t     double,
  r1    double,
  r2    double,
  i     double,
  rate  double,
  unique index(bundle_id), 
  index(rate) );

insert into regression 
  ( bundle_id, sx0x0, sx0x1, sx0x2, sx0y, sx1x1, sx1x2, sx1y, sx2x2, sx2y)
select 
  bundle_id, 
  sum(w)       as sx0x0,
  sum(w*x1)    as sx0x1,
  sum(w*x2)    as sx0x2,
  sum(w*y)     as sx0y,
  sum(w*x1*x1) as sx1x1,
  sum(w*x1*x2) as sx1x2,
  sum(w*x1*y)  as sx1y,
  sum(w*x2*x2) as sx2x2,
  sum(w*x2*y)  as sx2y
from regression_data
group by bundle_id; 

update regression set det1 = sx0x0*sx1x1 - sx0x1*sx0x1;

update regression set 
  o1b1 = ( sx0y*sx1x1 - sx0x1*sx1y ) / det1,
  o1b2 = ( sx0x0*sx1y - sx0x1*sx0y ) / det1;
  
update regression r set 
  r.det2 = sx0x0*sx1x1*sx2x2 - sx0x2*sx0x2*sx1x1 + 2*sx0x1*sx0x2*sx1x2 - 
           sx0x0*sx1x2*sx1x2 - sx0x1*sx0x1*sx2x2; 

update regression r set 
  r.o2b1 = ( sx0x2*sx1x2*sx1y - sx0y*sx1x2*sx1x2 + sx0y*sx1x1*sx2x2 - 
             sx0x1*sx1y*sx2x2 - sx0x2*sx1x1*sx2y + sx0x1*sx1x2*sx2y ) / det2, 
  r.o2b2 = ( sx0x2*sx0y*sx1x2 - sx0x2*sx0x2*sx1y - sx0x1*sx0y*sx2x2 + 
             sx0x0*sx1y*sx2x2 + sx0x1*sx0x2*sx2y - sx0x0*sx1x2*sx2y ) / det2, 
  r.o2b3 = ( sx0x1*sx0y*sx1x2 - sx0x2*sx0y*sx1x1 + sx0x1*sx0x2*sx1y - 
             sx0x0*sx1x2*sx1y - sx0x1*sx0x1*sx2y + sx0x0*sx1x1*sx2y ) / det2;

update regression r
join indicator_time t on t.bundle_id = r.bundle_id
set r.t = t.t; 

update regression set 
  r1 = o1b2, 
  r2 = o2b2 + 2*o2b3*t; 
  

/* Quadratic tempering  */ 

/* ascension limit */
set @fqtalim = case @solicitation_type when 'DM' then 2 when 'PAT' then 2 end; 

/* descension limit */
set @fqtdlim = case @solicitation_type when 'DM' then -1 when 'PAT' then -1 end; 

/* descension delay */
set @fqtddel = case @solicitation_type when 'DM' then 3.5 when 'PAT' then 3.5 end; 

/* descension sharpness */
set @fqtdshp = case @solicitation_type when 'DM' then 3.8 when 'PAT' then 3.8 end; 

update regression set i = ( coalesce(r2,r1) - r1 ) / r1;

update regression set rate = r1 + r1*if( i >= 0, 
    i  /  pow(1 + pow( i/@fqtalim ,4) ,1/4),
    @fqtdlim - @fqtdlim/(1 + pow(-i/@fqtddel,@fqtdshp) ) 
  ); 

update bundle b
join regression r on r.bundle_id = b.id
set b.aa_rate = r.rate; 




/* ====================================================================== */
/*                      Power Mean                                        */
/* ====================================================================== */

/* power mean exponent  */ 
set @fpme = case @solicitation_type when 'DM' then 3 when 'PAT' then 3 end; 
update bundle b
join (
  select 
    bundle_id, 
    pow( sum(wf*pow(amt*mul,@fpme)) / sum(wf) , 1/@fpme ) as mean
  from contrib_worksheet 
  group by bundle_id
  ) c on c.bundle_id = b.id
set b.aa_mean = c.mean; 


/* ====================================================================== */
/*                      "meat" amount                                     */
/* ====================================================================== */
/* A combination of the "mean" model and the "rate" model -- the "meat" model!*/ 

/* first of all, if the rate is less than the mean, throw it out */ 
update bundle set aa_rate = null where aa_rate < aa_mean; 

/* now, use the rate and the mean to make some meat */ 
update bundle 
left join bundle_rate_qualification rate on rate.bundle_id = bundle.id
set aa_meat = 
  case 
    when aa_mean is null and aa_rate is null then
      coalesce(aa_baseline,0)
    when aa_mean is not null and aa_rate is not null then
      /*  Take a weighted average between rate model and mean model using 
          rate.qualification as the weight, which we know to be 
          between 0 and 1 */ 
      coalesce(rate.qualification,0) * aa_rate  +  
      ( 1 - coalesce(rate.qualification,0) ) * aa_mean 
    else coalesce(aa_mean, aa_rate)
  end;


/* ====================================================================== */
/*                      Recency subtraction                               */
/* ====================================================================== */

/* subtraction maximum */ 
set @fsubmax = case @solicitation_type when 'DM' then 1 when 'PAT' then 1.5 end;

/* subtraction extent */ 
set @fsubext = case @solicitation_type when 'DM' then 0.2 when 'PAT' then 0.43 end;

/* descension sharpness */ 
set @fsubshp = case @solicitation_type when 'DM' then 5 when 'PAT' then 4.7 end;

update contrib_worksheet 
set sub = @fsubmax*amt*subw/( 1 + pow(ybn/@fsubext,@fsubshp) );

update bundle 
join (
  select 
    bundle_id,
    sum(coalesce(sub,0)) as sub
  from contrib_worksheet 
  group by bundle_id
  ) c on c.bundle_id = bundle.id
set bundle.aa_sub = c.sub;


/* ====================================================================== */
/*                      Expected amount                                   */
/* ====================================================================== */

update bundle set aa_expected = greatest( aa_meat - aa_sub, 0 );
    
/* ====================================================================== */
/*                      raw ask amount                                    */
/* ====================================================================== */

/* multiply the expected amount by this value to get the ask amount */ 
set @ask_stretch = 1.2; 

update bundle set aa_raw = aa_expected * @ask_stretch; 


/* ====================================================================== */
/*                      ask amount rounding floor                         */
/* ====================================================================== */


set @ask_rf_stretch = 1.1; 
update bundle set aa_rf = aa_expected * @ask_rf_stretch; 




/* ====================================================================== */
/*                      Rounding                                          */
/* ====================================================================== */



drop table if exists round_amounts; 
create table round_amounts (
  yearly_amount int(6), 
  monthly_amount int(6),
  unique index(yearly_amount),
  index(monthly_amount) ); 
insert into round_amounts values
    (0, NULL),
    (5, NULL),
   (10, NULL),
   (15, NULL),
   (20, NULL),
   (25, NULL),
   (30, NULL),
   (35, NULL),
   (40, NULL),
   (50, 5),
   (75, 7),
  (100, 10),
  (125, 10),
  (150, 15),
  (175, 15),
  (200, 17),
  (250, 20),
  (300, 25),
  (350, 30),
  (400, 35),
  (500, 40),
  (600, 50),
  (700, 60),
  (800, 70),
 (1000, 80),
 (1200, 100),
 (1500, 125),
 (1800, 150),
 (2000, 170),
 (2500, 200),
 (3000, 250),
 (3500, 300),
 (4000, 350),
 (5000, 400),
 (6000, 500),
 (7500, 600),
(10000, 850),
(12000, 1000),
(15000, 1200),
(20000, 1700);

update bundle set aa_round = null; 
set @max_ask = ( select max(yearly_amount) from round_amounts ); 
update bundle 
join ( select 
    bundle.id as bundle_id,
    aa_expected,
    min(above.yearly_amount) as result
  from bundle
  join round_amounts above on above.yearly_amount >= bundle.aa_rf
  group by bundle.id
  ) rounded on rounded.bundle_id = bundle.id
set bundle.aa_round = rounded.result;

update bundle set aa_round = @max_ask where aa_round is null;

update bundle b
join round_amounts r on r.yearly_amount = b.aa_round
set b.aa_monthly = r.monthly_amount; 





/**************************************************************************/
/**************************************************************************/
/***                                                                    ***/
/***                    Likelihood                                      ***/
/***                                                                    ***/
/**************************************************************************/
/**************************************************************************/



/* contributions that qualify as affirmative events */ 
drop temporary table if exists affirmative_contribs; 
create temporary table affirmative_contribs (
  contact_id int(10),
  receive_date datetime,
  index(contact_id), 
  index(receive_date) ); 
insert into affirmative_contribs select 
  contrib.contact_id,
  contrib.receive_date
from civicrm_contribution contrib 
join valid_contribs on valid_contribs.id = contrib.id
join financial_type_weights ctype on 
  ctype.financial_type_id = contrib.financial_type_id and 
  ctype.affirmative_event = 1;


/* Days since the most recent affirmative event */ 
drop temporary table if exists affirmative_events;
create temporary table affirmative_events (
  bundle_id int(10), 
  ybn decimal(6,4) comment "years before now", 
  index(bundle_id), 
  index(ybn) ); 
  
/* affirmative events from contributions */ 
insert into affirmative_events select 
  bundle.id,
  datediff( @now, ac.receive_date)/365.0 as ybn
from bundle
join contact_bundle cb on cb.bundle_id = bundle.id
join affirmative_contribs ac on ac.contact_id = cb.contact_id
having ybn > 0.0;

/* affirmative events from the first log entry */ 
insert into affirmative_events select id, yafl 
  from bundle where yafl is not null; 

/* compute the time since the last affirmative event */ 
update contrib_worksheet c
join (
  select 
    id,
    min( ae.ybn - c.ybn ) as ta
  from contrib_worksheet c
  join affirmative_events ae on ae.bundle_id = c.bundle_id 
  where ae.ybn >= c.ybn
  group by c.id
  ) result on result.id = c.id
set c.ta = result.ta
where c.ta is null;
/* For any contributions where we were unable to compute the time since the 
   last affirmative event, we'll assume zero here. There are relatively few of
   these cases. It mostly seems to happen when a contact is created upon 
   receiving a check and the date of the check will be before the contact gets
   create in our database (makes sense). */ 
update contrib_worksheet
set ta = 0
where ta is null;

  
/* readiness */ 

/* specific readiness curve start, when fully delayed */
set @frdcs = case @solicitation_type when 'DM' then 0.1 when 'PAT' then 0.1 end; 

/* specific readiness curve end, when fully delayed */
/* This is set to 1 so that we can set values for 
  `financial_type_weights`.`likelihood_readiness_delay` in units of 1 year */
set @frdce = case @solicitation_type when 'DM' then 1 when 'PAT' then 1 end; 

update contrib_worksheet c set 
rds = if( ybn < rdd*@frdcs, rdi, if(ybn > rdd*@frdce, 1, 
    rdi + 
      (
        (rdi-1)*pow(rdd*@frdcs-ybn,3)*
        ( 
            pow(rdd,2)*(10*pow(@frdce,2) 
          - 5*@frdce*@frdcs+pow(@frdcs,2)) 
          + 3*rdd*(@frdcs-5*@frdce)*ybn 
          + 6*pow(ybn,2) 
        )
      )/
      (pow(rdd,5)*pow(@frdce-@frdcs,5))
  ));



/* initial dedication value */
set @fdi = case @solicitation_type when 'DM' then 0.2 when 'PAT' then 0.2 end; 

/* reliability decay time, in years */ 
set @frt = case @solicitation_type when 'DM' then 4.0 when 'PAT' then 3.0 end; 

/* dedication decay sharpness when fully reliable */
set @fdsr = case @solicitation_type when 'DM' then 3.7 when 'PAT' then 3.7 end; 

/* dedication decay sharpness when fully unreliable */
set @fdsu = case @solicitation_type when 'DM' then 1.8 when 'PAT' then 1.8 end; 

/* dedication decay weight when fully reliable */
set @fdwr = case @solicitation_type when 'DM' then 0.22 when 'PAT' then 0.22 end; 

/* dedication decay weight when fully unreliable */
set @fdwu = case @solicitation_type when 'DM' then 0.5 when 'PAT' then 0.5 end; 

/* bolster value at zero -- when co=1 and cdb=0  */
set @fbvz = case @solicitation_type when 'DM' then 0.47 when 'PAT' then 0.47 end;

/* bolster slope at zero -- slope of cda vs cdb when co=1 and cdb=0 */
set @fbsz = case @solicitation_type when 'DM' then 0.15 when 'PAT' then 0.15 end; 

/* bolster slope at one -- slope of cda vs cdb when co=1 and cdb=1 */
set @fbso = case @solicitation_type when 'DM' then 0.15 when 'PAT' then 0.15 end; 

/* variables (that will get changed per-row in the following update */ 
set @dbr = 0.0; 
set @dbu = 0.0; 
set @db = 0.0; 
set @bs = 0.0;
set @pda = 0.0;
set @prb = 0.0;
set @pybn = 0.0;
set @pcrds = 0.0;
update contrib_worksheet c set 

/* VALUES FOR THIS ROW COMPUTED DIRECTLY FROM THIS ROW */
  
  /* dedication immediately before the current contribution, if rb=1 */ 
  dbr = @dbr := if(is_first, null, @pda/(1 + pow(@fdwr*tc,@fdsr)) ),
  
  /* dedication immediately before the current contribution, if rb=0 */
  dbu = @dbu := if(is_first, null, @pda/(1 + pow(@fdwu*tc,@fdsu)) ),
  
  /* dedication immediately before the current contribution */ 
  db =  @db  := if(is_first, db, @dbu + (@dbr - @dbu)* @prb ),
  
  /* bolster strength of the current contribution and its point in time */ 
  bs =  @bs  := op/(1 + pow(1-rs,4)*pow(ta,2) ),
  

/* COMPUTED VALUES FOR THIS ROW THAT SHOULD ALSO BE CARRIED OVER TO THE NEXT ROW */ 
  
  /* dedication immediately after the current contribution */ 
  da = @pda :=  @db + 
    @bs*(@fbvz+@db*((@db-1)*(1-@fbsz+@db*(@fbso+@fbsz-2))+(2*@db-3)*@db*@fbvz)),
  
  /* reliability of this contribution, at its point in time */ 
  rb =  @prb := if(ta > @frt, 0, 1-ta/@frt),
  
  /* cumulative readiness */
  crds = @pcrds := if(is_first, 1, @pcrds) * coalesce(rds,1), 

/* SIMPLE VALUES TO CARRY OVER TO THE NEXT ROW */ 

  ybn = @pybn := ybn;


/* calculate final dedication and readiness values */ 
update bundle b
join contrib_worksheet c on c.bundle_id = b.id
set 
  b.lh_dedication = c.db,
  b.lh_readiness  = crds
where c.cid is null;

/* calculate final likelihood values */ 
update bundle set likelihood = lh_dedication * lh_readiness; 





/**************************************************************************/
/**************************************************************************/
/***                                                                    ***/
/***                    Priority                                        ***/
/***                                                                    ***/
/**************************************************************************/
/**************************************************************************/


/* priority asecension vs ask amount */ 
set @fprasc = case @solicitation_type when 'DM' then 0.03 when 'PAT' then 0.03 end; 

/* priority sharpness when asecending vs ask amount */ 
set @fprshp = case @solicitation_type when 'DM' then 0.9 when 'PAT' then 0.9 end; 

update bundle set priority = 
  likelihood*(1 - 1/(1 + pow(@fprasc*aa_raw,@fprshp) ));


/* ====================================================================== */
/*                      first choose fresh contacts                       */
/* ====================================================================== */


/* who is fresh? (i.e. who has never given?) */ 
update bundle 
left join contrib_worksheet cw on 
  cw.bundle_id = bundle.id and 
  cw.cid is not null and 
  cw.ws > 0 /* Only consider contributions that have some weight to them, so 
        having a "purchase" contrib will still allow the bundle to be fresh */ 
set is_fresh = 1
where cw.bundle_id is null; 


/* reset *
update bundle set is_fresh = 0, is_chosen = 0; 
/* chose all the fresh bundles that are new enough */ 
update bundle 
set is_chosen = 1 
where 
  is_fresh = 1 and 
  is_excluded != 1 and 
  yafl < @fresh_bundle_inclusion_window_years;

/* how many did we just grab? */ 
set @fresh_included_count = (select count(*) from bundle where is_chosen = 1);
  

/* ====================================================================== */
/*         next, fill up the rest of our list with non-fresh contacts     */
/* ====================================================================== */

/* write the sort order into the bundle table */ 
set @prev_list_order = 0; 
update bundle
set list_order = @prev_list_order := @prev_list_order + 1
where is_excluded != 1 and is_chosen != 1
order by priority desc; 

/*  fill up the rest of the mailing list by highest priority */
update bundle 
set is_chosen = 1 
where 
  list_order <= @desired_results_quantity - @fresh_included_count;


/* chosen contacts (for performance enhancements later on) 
This table can be used to speed up subsequent queries by performing the given
operation only on the small subset of contacts that we want to solicit */ 
drop temporary table if exists chosen_contacts; 
create temporary table chosen_contacts like simple_contact_table; 
insert into chosen_contacts select cb.contact_id
  from contact_bundle cb 
  join bundle on bundle.id = cb.bundle_id
  where bundle.is_chosen = 1; 

/**************************************************************************/
/**************************************************************************/
/***                                                                    ***/
/***                    Difficulty                                      ***/
/***                                                                    ***/
/**************************************************************************/
/**************************************************************************/

set @fdiffslope = 6;
set @fdiffspacing = 0.12;
set @fdiffoffset = -0.4;

update bundle set 
  difficulty = 10* 
    (ln(aa_raw) - @fdiffoffset*@fdiffslope - @fdiffslope*likelihood)
      / (@fdiffslope*@fdiffspacing);





/**************************************************************************/
/**************************************************************************/
/***                                                                    ***/
/***                   PAT Pile                                         ***/
/***                                                                    ***/
/**************************************************************************/
/**************************************************************************/



/* ====================================================================== */
/*               priority_level                                            */
/* ====================================================================== */

set @priority_level_size = @desired_results_quantity/@priority_level_divisions;

update bundle set 
  priority_level = char( 65 + floor((list_order-1)/@priority_level_size) )
  where is_chosen = 1 and 
  @solicitation_type = 'PAT'; 


/* ====================================================================== */
/*               difficulty_level                                         */
/* ====================================================================== */

drop temporary table if exists difficulty_worksheet; 
create temporary table difficulty_worksheet ( 
  bundle_id int(10), 
  priority_level char(2),
  difficulty double, 
  bundle_ordinal int(5),
  difficulty_level_ordinal int(2),
  unique index(bundle_id),
  index(priority_level),
  index(bundle_ordinal),
  index(difficulty_level_ordinal),
  index(priority_level,difficulty_level_ordinal)); 
insert into difficulty_worksheet (bundle_id, priority_level, difficulty) select
    id, 
    priority_level, 
    difficulty
  from bundle
  where 
    is_chosen = 1 and 
    @solicitation_type = 'PAT'
  order by priority_level, difficulty;

set @prev_priority_level = " ";
set @prev_ordinal = 0; 
update difficulty_worksheet set 
  bundle_ordinal = @prev_ordinal := if(priority_level = @prev_priority_level,  
    @prev_ordinal + 1, 1), 
  priority_level = @prev_priority_level := priority_level; 

set @difficulty_level_size = 
  1.0 * @priority_level_size / @difficulty_level_divisions;
update difficulty_worksheet set 
  difficulty_level_ordinal = ceil(bundle_ordinal/@difficulty_level_size-0.0001);

drop temporary table if exists difficulty_level;
create temporary table difficulty_level (
  priority_level char(2),
  difficulty_level_ordinal int(2),
  difficulty_avg double, 
  difficulty_level int(2),
  unique index(priority_level,difficulty_level_ordinal) ); 
insert into difficulty_level select 
    priority_level, 
    difficulty_level_ordinal, 
    avg(difficulty) as difficulty_avg,
    null as difficulty_level
  from difficulty_worksheet
  group by priority_level, difficulty_level_ordinal;
update difficulty_level set 
  difficulty_level = least( greatest( round(difficulty_avg), 10), 90);
  
update bundle  
join difficulty_worksheet dw on dw.bundle_id = bundle.id 
join difficulty_level dl on 
  dl.priority_level = dw.priority_level and 
  dl.difficulty_level_ordinal = dw.difficulty_level_ordinal
set 
  bundle.difficulty_level = dl.difficulty_level;

/* ====================================================================== */
/*               pile                                                     */
/* ====================================================================== */

update bundle 
set pile = concat(priority_level, difficulty_level)
where @solicitation_type = 'PAT';


/**************************************************************************/
/**************************************************************************/
/***                                                                    ***/
/***                    Results                                         ***/
/***                                                                    ***/
/**************************************************************************/
/**************************************************************************/


/* ====================================================================== */
/*               bundle name and  primary contact ID                      */
/* ====================================================================== */


/* LOGIC TO USE:
IF we have at least one household name, and the bundle is approved for household name usage
    then use the one household name with the highest clout
ELSE IF we have at least one an organization name, 
    then use the one organization name with the highest clout
ELSE use a concatenatenation of the TWO individual names who have the higest clout
*/ 


/* clout */  
drop temporary table if exists non_fresh_clout; 
create temporary table non_fresh_clout (
  contact_id int(10), 
  clout int(10), 
  unique index(contact_id), 
  unique index(clout) ); 
insert into non_fresh_clout select  
    contrib.contact_id, 
    round(least(sum(cw.wf) * 100, 999),0)*1000000 + contrib.contact_id total_weight 
  from contrib_worksheet cw
  join civicrm_contribution contrib on contrib.id = cw.cid
  join chosen_contacts cc on cc.contact_id = contrib.contact_id /* for performance */
  group by contrib.contact_id;
drop temporary table if exists clout; 
create temporary table clout like non_fresh_clout; 
insert into clout select 
    contact.id as contact_id,
    coalesce(nfc.clout, contact.id) as clout
  from civicrm_contact contact 
  join chosen_contacts cc on cc.contact_id = contact.id /* for performance */
  left join non_fresh_clout nfc on nfc.contact_id = contact.id; 


/* display name for all single contacts */ 
drop temporary table if exists contact_name; 
create temporary table contact_name (
  contact_id int(10), 
  name char(100), 
  unique index(contact_id) ); 
insert into contact_name select 
    id,
    case contact_type
      when 'Individual' then 
        coalesce(
          concat(
            coalesce(contact.nick_name, contact.first_name),' ',
            contact.last_name), 
          contact.display_name)
      when 'Household' then household_name
      when 'Organization' then organization_name
      else display_name
    end
  from civicrm_contact contact;
  /* this table is also used to give names to riders in BATRS contrib notes, so
  we do have to compute the name for EVERY contact, not just the ones selected*/

  
/* ====================================================================== */
/*               bundle name and  primary contact ID                      */
/* ====================================================================== */

/* name worksheet */ 
drop temporary table if exists name_worksheet;
create temporary table name_worksheet (
  bundle_id int(10), 
  contact_id int(10), 
  contact_type enum('Individual','Household','Organization'), 
  clout int(10),
  ordinal int(3), 
  contact_name char(100), 
  index(bundle_id), 
  unique index(contact_id), 
  index(contact_type),
  index(ordinal) ); 
insert into name_worksheet select 
    cb.bundle_id, 
    cb.contact_id, 
    contact.contact_type,
    clout.clout,
    null as ordinal,
    name.name
  from civicrm_contact contact
  join contact_name name on name.contact_id = contact.id
  join contact_bundle cb on cb.contact_id = contact.id
  join clout on clout.contact_id = contact.id
  join chosen_contacts cc on cc.contact_id = contact.id /* for performance */ 
  left join contact_exclude x on x.contact_id = contact.id 
  left join exclude_strategy strat on strat.importance = x.strategy_importance
  where 
    (strat.name_appears_in_bundle = 1 OR strat.name_appears_in_bundle is null )
  order by cb.bundle_id, contact_type, clout.clout desc;
set @prev_bundle_id = 0; 
set @prev_contact_type = ''; 
set @prev_ordinal = 0; 
update name_worksheet set 
  ordinal = @prev_ordinal := 
    if(bundle_id != @prev_bundle_id OR contact_type != @prev_contact_type, 
      1 /* new bundle or new contact type */, 
      @prev_ordinal + 1 /* continued bundle and contact type */ ),
  bundle_id = @prev_bundle_id := bundle_id, 
  contact_type = @prev_contact_type := contact_type; 

/* which bundles won't tolerate using household name in bundle */ 
drop table if exists house_name_forbidden;
create temporary table house_name_forbidden like simple_bundle_table; 
insert into house_name_forbidden select distinct 
    cb.bundle_id
  from contact_exclude x
  join exclude_strategy strat on strat.importance = x.strategy_importance
  join contact_bundle cb on cb.contact_id = x.contact_id
  join chosen_contacts cc on cc.contact_id = x.contact_id /* for performance */ 
  where strat.allows_house_name_in_bundle = 0; 
  
/* naming technique */ 
drop temporary table if exists naming_technique; 
create temporary table naming_technique (
  bundle_id int(10), 
  technique enum('Individual','Household','Organization'), 
  unique index(bundle_id), 
  index(technique) ); 

/* lowest priority technique -- Individual */ 
insert into naming_technique select 
  bundle_id,
  'Individual' as technique
from name_worksheet nw
left join contact_exclude x on x.contact_id = nw.contact_id 
left join exclude_strategy strat on strat.importance = x.strategy_importance
where 
  nw.contact_type = 'Individual' and 
  (strat.name_appears_in_bundle = 1 OR strat.name_appears_in_bundle is null )
group by bundle_id;

/* medium priority technique -- Organization (trumps Individual) */ 
insert into naming_technique select 
  bundle_id,
  'Organization' as technique
from name_worksheet nw
left join contact_exclude x on x.contact_id = nw.contact_id 
left join exclude_strategy strat on strat.importance = x.strategy_importance
where 
  nw.contact_type = 'Organization' and 
  (strat.name_appears_in_bundle = 1 OR strat.name_appears_in_bundle is null )
group by bundle_id
on duplicate key update technique = 'Organization'; 

/* highest priority technique -- Household (trumps Organization and Individual) */ 
insert into naming_technique select 
  nw.bundle_id,
  'Household' as technique
from name_worksheet nw
left join contact_exclude x on x.contact_id = nw.contact_id 
left join exclude_strategy strat on strat.importance = x.strategy_importance
left join house_name_forbidden hnf on hnf.bundle_id = nw.bundle_id 
where 
  nw.contact_type = 'Household' and 
  (strat.name_appears_in_bundle = 1 OR strat.name_appears_in_bundle is null ) and
  hnf.bundle_id is null /* house name is NOT forbidden */ 
group by bundle_id
on duplicate key update technique = 'Household'; 

/* pick one contact for each bundle that is the most important */ 
drop temporary table if exists bundle_primary_contact; 
create temporary table bundle_primary_contact (
  bundle_id int(10), 
  contact_id int(10), 
  unique index(bundle_id), 
  unique index(contact_id) ); 
insert into bundle_primary_contact select 
  nw.bundle_id, 
  nw.contact_id
from name_worksheet nw
join naming_technique nt using (bundle_id)
where nw.contact_type = nt.technique and nw.ordinal = 1
group by nw.bundle_id;

/* bundle name */ 
drop temporary table if exists bundle_name; 
create temporary table bundle_name (
  bundle_id int(10), 
  name char(200), 
  unique index(bundle_id) ); 

/* organization names */ 
insert into bundle_name select 
  nw.bundle_id, 
  nw.contact_name
from name_worksheet nw
join naming_technique nt using (bundle_id)
where 
  nt.technique = 'Organization' and 
  nw.contact_type = 'Organization' and 
  nw.ordinal = 1
group by nw.bundle_id;

/* Household names */ 
insert into bundle_name select 
  nw.bundle_id, 
  nw.contact_name
from name_worksheet nw
join naming_technique nt using (bundle_id)
where 
  nt.technique = 'Household' and 
  nw.contact_type = 'Household' and 
  nw.ordinal = 1
group by nw.bundle_id;

/* individual names */ 
insert into bundle_name select 
  nw.bundle_id, 
  group_concat(
    distinct nw.contact_name order by nw.ordinal desc separator ' and ' )
from name_worksheet nw
join naming_technique nt using (bundle_id)
where 
  nt.technique = 'Individual' and 
  nw.contact_type = 'Individual' and 
  nw.ordinal <= 2
group by nw.bundle_id;



/* ====================================================================== */
/*               contributions to display                                 */
/* ====================================================================== */

set @displayed_contribs_count = 19; 

drop temporary table if exists displayed_contribs;
create temporary table displayed_contribs (
  bundle_id int(10),
  contact_id int(10),
  contrib_id int(10) not null,
  ordinal int(4), 
  marker char(5) character set utf8,
  amount decimal(7,2), 
  instrument char(5) character set utf8,
  code char(20), 
  recdate datetime, 
  note char(100), 
  index(bundle_id), 
  index(contact_id), 
  index(contrib_id), 
  index(ordinal) ); 
insert into displayed_contribs select 
    cw.bundle_id, 
    contrib.contact_id, 
    contrib.id as contrib_id, 
    null as ordinal, 
    null as marker, 
    contrib.total_amount as amount, 
    case instrument.value
      when 3 then "⛀" /* cash */ 
      when 1 then "✪" /* credit */ 
      else "▭"        /* check */ 
      end as instrument, 
    substr(
        ctype.name, 
        locate('(',ctype.name) + 1, 
        locate(')',ctype.name) - locate('(',ctype.name) - 1 
      ) as code,
    receive_date as recdate,
    concat("for ", group_concat(distinct soft_name.name) ) as note
  from contrib_worksheet cw 
  join civicrm_contribution contrib on contrib.id = cw.cid
  left join civicrm_option_value instrument on 
    instrument.value = contrib.payment_instrument_id and 
    instrument.option_group_id = 10
  join civicrm_financial_type ctype on 
    ctype.id = contrib.financial_type_id
  left join civicrm_contribution_soft soft on soft.contribution_id = contrib.id
  left join contact_name soft_name on soft_name.contact_id = soft.contact_id
  join chosen_contacts cc on cc.contact_id = contrib.contact_id /* +performance */ 
  where 
    contrib.contribution_recur_id is null and  /* no recurring */ 
    cw.ws > 0 /* must have some simple weight */ 
   /* choose heaviest contribs first, using full weight  */
  group by contrib.id
  order by cw.bundle_id, wf desc;

/* number each contrib within the bundle */ 
set @prev_bundle_id = 0; 
set @prev_ordinal = 0; 
update displayed_contribs set 
  ordinal = @prev_ordinal := if(bundle_id=@prev_bundle_id, @prev_ordinal+1, 1),
  bundle_id = @prev_bundle_id := bundle_id; 
  /* TODO: hmmm for some reason this takes waaaay to long. WAT??? */ 

/* only show some contribs */ 
delete from displayed_contribs where ordinal > @displayed_contribs_count; 



/* ====================================================================== */
/*               name summary                                             */
/* ====================================================================== */

/*
Anyone 
  with contributions OR 
  with phone numbers that don't have contributions OR
  cloaked 
*/

/* phone numbers that don't exist on any contacts with contributions */ 
drop temporary table if exists fresh_phones; 
create temporary table fresh_phones (
  phone_compare char(12), 
  unique index(phone_compare) ); 
insert into fresh_phones select 
    phone_compare
  from contact_phones cp
  left join displayed_contribs dc on dc.contact_id = cp.contact_id
  join chosen_contacts cc on cc.contact_id = cp.contact_id /* +performance */ 
  group by phone_compare
  having max(dc.contrib_id) is null; 

/* who do we want to be in the name summary? */ 
drop temporary table if exists contacts_to_name; 
create temporary table contacts_to_name like simple_contact_table; 

  /* contacts that have contributions */ 
  insert ignore into contacts_to_name select dc.contact_id
    from displayed_contribs dc
    join chosen_contacts cc on cc.contact_id = dc.contact_id; /* +performance */ 

  /* contacts that have fresh phone numbers */ 
  insert ignore into contacts_to_name select cp.contact_id
    from fresh_phones fp
    join contact_phones cp on cp.phone_compare = fp.phone_compare
    join chosen_contacts cc on cc.contact_id = cp.contact_id; /* +performance */ 

  /* anyone whose name should be forced (e.g. deceased ) */ 
  insert ignore into contacts_to_name select exclude.contact_id
  from exclude
  join exclude_situation sit on sit.name = exclude.situation 
  join exclude_strategy strat on strat.name = sit.strategy
  where strat.force_name_in_summary; 
  

/* all names for the bundles */ 
drop temporary table if exists name_detail_worksheet; 
create temporary table name_detail_worksheet (
  bundle_id int(10), 
  contact_id int(10),
  ordinal int(3), 
  use_markers int(1) not null default 0, 
  marker char(5) character set utf8,
  contact_type char(100),
  is_deceased int(1) not null default 0, 
  name char(100), 
  pronounce char(50), 
  age int(3),
  index(bundle_id), 
  index(ordinal), 
  index(use_markers),
  index(age) ); 
insert into name_detail_worksheet (
    bundle_id, 
    contact_id,
    contact_type,
    is_deceased,
    name,
    pronounce,
    age)
  select 
    cb.bundle_id, 
    cb.contact_id,
    contact.contact_type,
    if( coalesce(contact.is_deceased,0) = 1 OR 
        contact.deceased_date is not null, 
        1, 0) as is_deceased, 
    contact_name.name, 
    cust.name_pronunciation_30 as pronounce,
    timestampdiff(year, contact.birth_date, @now)  as age
  from contact_bundle cb
  join civicrm_contact contact on contact.id = cb.contact_id
  join contacts_to_name on contacts_to_name.contact_id = cb.contact_id
  join chosen_contacts on chosen_contacts.contact_id = cb.contact_id
  join contact_name on contact_name.contact_id = cb.contact_id
  left join civicrm_value_donation_information_2 cust on 
    cust.entity_id = cb.contact_id
  join clout on clout.contact_id = cb.contact_id
  order by cb.bundle_id, clout desc; 

/* clean up name pronunciation */ 
update name_detail_worksheet
set pronounce = null
where length(pronounce) < 2; 
  
/* number each named contact within the bundle */ 
set @prev_bundle_id = 0; 
set @prev_ordinal = 0; 
update name_detail_worksheet set 
  ordinal = @prev_ordinal := if(bundle_id=@prev_bundle_id, @prev_ordinal+1, 1),
  bundle_id = @prev_bundle_id := bundle_id; 

/* how many contact names are we displaying for a given bundle? */ 
drop temporary table if exists contacts_displayed; 
create temporary table contacts_displayed (
  bundle_id int(10), 
  quant int(3), 
  unique index(bundle_id), 
  index(quant) );
insert into contacts_displayed select 
    bundle_id,
    max(ordinal) as quant
  from name_detail_worksheet
  group by bundle_id; 

/* decide to only use markers for bundles where we have more than one name */ 
update name_detail_worksheet
join contacts_displayed on 
  contacts_displayed.bundle_id = name_detail_worksheet.bundle_id
set use_markers = 1
where contacts_displayed.quant > 1; 

/* markers */ 
drop temporary table if exists marker; 
create temporary table marker (
  ordinal int(3), 
  marker char(5) character set utf8,
  unique index(ordinal) ); 
insert into marker values 
(1,'①'),
(2,'②'),
(3,'③'),
(4,'④'),
(5,'⑤'),
(6,'⑥'),
(7,'⑦'),
(8,'⑧'),
(9,'⑨');
update name_detail_worksheet ndw
join marker on marker.ordinal = ndw.ordinal
set ndw.marker = marker.marker
where ndw.use_markers = 1; 

/* final name summary for each bundle */ 
drop temporary table if exists name_summary; 
create temporary table name_summary like simple_bundle_summary_table;
insert into name_summary select 
    bundle_id, 
    group_concat( 
      concat( 
        coalesce(concat(marker,' '), ''),  
        
        if(coalesce(is_deceased,0),'(DECEASED) ', ''), 
        
        name,
        
        coalesce(concat(' (',pronounce,')'),''), 
        
        if( contact_type = 'Individual',
          coalesce(concat(', age ', age),''),
          '' )
        )
      order by ordinal
      separator '\n'
      ) as summ
  from name_detail_worksheet 
  group by bundle_id; 


/* ====================================================================== */
/*                  contrib_summary                                       */
/* ====================================================================== */


update displayed_contribs dc
join name_detail_worksheet ndw on ndw.contact_id = dc.contact_id
set dc.marker = ndw.marker; 


drop temporary table if exists contrib_summary;
create temporary table contrib_summary like simple_bundle_summary_table; 
insert into contrib_summary select 
    bundle_id, 
    group_concat(
      concat_ws('\t',
        coalesce(marker,''),
        concat('$',format(amount,0)), 
        coalesce(code,''), 
        coalesce(instrument,''), 
        coalesce(date_format(recdate,'%Y-%b'),''),
        coalesce(note,'') )
      order by recdate desc
      separator '\n' ) as summ
  from displayed_contribs
  group by bundle_id; 



/* ====================================================================== */
/*                      Address                                           */
/* ====================================================================== */

/* we choose one address per bundle
Logic: Look at all the addresses in the bundle, pick the one that: 
  first and foremost has the lowest exclusion situation strategy importance
  second, is primary, 
  lastly, has the highest address id
This basically takes the most recent primary address from non-excluded contacts
*/ 

drop temporary table if exists address_worksheet; 
create temporary table address_worksheet (
  bundle_id int(10), 
  number_one int(1),
  address_id int(10),
  index(bundle_id),
  index(number_one) ); 
insert into address_worksheet select 
  bundle.id as bundle_id,
  null as number_one, 
  address.id as address_id
from bundle
join contact_bundle cb on cb.bundle_id = bundle.id 
join contact_addresses ca on ca.contact_id = cb.contact_id
join civicrm_address address on address.id = ca.address_id
left join contact_exclude x on x.contact_id = cb.contact_id 
left join exclude_strategy strat on strat.importance = x.strategy_importance
where bundle.is_chosen = 1
order by 
  bundle_id,
  coalesce(strat.importance,0) asc,
  address.is_primary desc,
  address.id desc;

set @prev_bundle_id = 0; 
update address_worksheet set 
  number_one = if(bundle_id = @prev_bundle_id, null, 1), 
  bundle_id = @prev_bundle_id := bundle_id; 

drop temporary table if exists bundle_address; 
create temporary table bundle_address (
  bundle_id int(10), 
  address_id int(10), 
  unique index(bundle_id), 
  unique index(address_id) ); 
insert into bundle_address select bundle_id, address_id
  from address_worksheet where number_one = 1; 

/* ====================================================================== */
/*                      Time zone                                         */
/* ====================================================================== */

drop temporary table if exists time_zone_summary; 
create temporary table time_zone_summary ( 
  bundle_id int(10), 
  hours_behind_eastern int(2), 
  summ char(100), 
  unique index(bundle_id) ); 
insert into time_zone_summary select 
  ba.bundle_id, 
  td.hours_behind_eastern, 
  case td.hours_behind_eastern
    when 0 then ""
    when 1 then "1 hour behind us"
    else concat(td.hours_behind_eastern, " HOURS BEHIND US!")
  end 
from bundle_address ba
join civicrm_address addr on addr.id = ba.address_id
join postal_code_time_difference td on td.postal_code = addr.postal_code;  



/* ====================================================================== */
/*                      Special thanks                                    */
/* ====================================================================== */

/* Dynamic special thanks 
/* some of this logic also exists in the generic contribution thank you search */ 
drop temporary table if exists dynamic_special_thanks; 
create temporary table dynamic_special_thanks (
  bundle_id int(10), 
  situation char(100), 
  unique index(bundle_id), 
  index(situation) ); 
  
/* Below are the different special thanks situations. When one bundle meets 
   multiple situations, the situation inserted LAST is the one that gets printed
   on the call sheet. */ 

/* bundles with high ask amount */ 
set @situation = "STAFF (due to high ask amount)";
insert into dynamic_special_thanks  select distinct
     bundle.id, @situation
  from bundle 
  where aa_round >= 500 and @solicitation_type = 'PAT'
  on duplicate key update situation = @situation;

/* contacts who have TPF soft-credits within the last year */ 
set @situation = "STAFF (due to soliciting third-party-fundraising)";
insert into dynamic_special_thanks  select distinct
    bundle_id, @situation
  from civicrm_contribution_soft soft 
  join civicrm_contribution contrib on contrib.id = soft.contribution_id
  join contact_bundle cb on cb.contact_id = soft.contact_id
  where 
    contrib.financial_type_id = 27 /* TPF */ and 
    contrib.is_test != 1 and 
    contrib.receive_date > @now - interval 1 year 
  on duplicate key update situation = @situation;

/* former staff */ 
set @situation = "STAFF (due to being former staff)";
insert into dynamic_special_thanks select distinct
    bundle_id, @situation
  from civicrm_group_contact gc
  join contact_bundle cb on cb.contact_id = gc.contact_id 
  where gc.group_id in (19, 20, 32)
  on duplicate key update situation = @situation;
  
/* given at least $1k in the last 10 months */ 
set @situation = "$1k in past 10 months"; 
insert into dynamic_special_thanks select  
    bundle_id, @situation
  from contrib_worksheet
  where ybn < 10/12
  group by bundle_id
  having sum(amt) >= 1000
  on duplicate key update situation = @situation;

/* contacts who have had BMB pledges */ 
set @situation = "BMB-P";
insert into dynamic_special_thanks select distinct
    cb.bundle_id, @situation
  from civicrm_pledge pledge
  join contact_bundle cb on cb.contact_id = pledge.contact_id
  where financial_type_id = 19 and is_test != 1
  on duplicate key update situation = @situation;

/* contacts who have had BMB recurring contributions */ 
set @situation = "BMB-R";
insert into dynamic_special_thanks  select distinct
    bundle_id, @situation
  from civicrm_contribution_recur recur
  join contact_bundle cb on cb.contact_id = recur.contact_id
  where financial_type_id = 19 and is_test != 1
  on duplicate key update situation = @situation;



  
/* manually set special thanks */ 
drop temporary table if exists hard_special_thanks; 
create temporary table hard_special_thanks (
  bundle_id int(10), 
  thanks char(200), 
  unique index(bundle_id) ); 
insert into hard_special_thanks select 
    cb.bundle_id,
    group_concat( distinct 
      cust.requires_special_thanks_by_5
      order by cust.requires_special_thanks_by_5
      separator ' or ' )
  from contact_bundle cb 
  left join civicrm_value_donation_information_2 cust on 
    cust.entity_id = cb.contact_id
  where length(cust.requires_special_thanks_by_5) > 1
  group by cb.bundle_id; 


/* full special thanks */ 
drop temporary table if exists special_thanks; 
create temporary table special_thanks (
  bundle_id int(10), 
  thanks char(200), 
  unique index(bundle_id) ); 
insert into special_thanks select 
    bundle.id,
    coalesce(h.thanks, d.situation) as thanks
  from bundle
  left join hard_special_thanks h on h.bundle_id = bundle.id
  left join dynamic_special_thanks d on d.bundle_id = bundle.id
  where (h.bundle_id is not null OR d.bundle_id is not null); 



/* ====================================================================== */
/*                      Mailing pile                                      */
/* ====================================================================== */
  
drop temporary table if exists mailing_pile; 
create temporary table mailing_pile (
  bundle_id int(10), 
  pile char(100), 
  unique index(bundle_id) ); 

/* hand address from special thanks */ 
insert into mailing_pile select 
    bundle_id,
    'Hand-address' as pile 
  from special_thanks
  where @solicitation_type = 'DM' 
  on duplicate key update pile = 'Foundation';

/* also hand address top priority who are not marked for special thanks */ 
insert into mailing_pile select 
    bundle.id,
    'Hand-address' as pile 
  from bundle
  left join special_thanks on special_thanks.bundle_id = bundle.id 
  where 
    special_thanks.bundle_id is null and 
    @solicitation_type = 'DM' 
  order by bundle.priority desc
  limit 20
  on duplicate key update pile = 'Foundation';
/* everyone who is marked as special thanks will automatically receive a
hand-written address label for mailings. And additionally we'll scrape the 
specified quantity off the top of the list (highest priority) for anyone who is
not marked as special thanks */ 

/* tagged as "Foundation/Funder" --> "Foundation" */ 
insert into mailing_pile select 
      cb.bundle_id,
      'Foundation' as pile 
    from civicrm_entity_tag tag
    join contact_bundle cb on cb.contact_id = tag.entity_id
    where 
      tag.tag_id = 62 and 
      tag.entity_table = 'civicrm_contact' and 
      @solicitation_type = 'DM' 
    on duplicate key update pile = 'Foundation';

/* has ever had a contribution of type "grant" --> "Foundation" */ 
insert into mailing_pile select 
    cb.bundle_id,
    'Foundation' as pile 
  from civicrm_contribution c
  join contact_bundle cb on cb.contact_id = c.contact_id
  where 
    c.financial_type_id = 6 /* GRANT */  and
    c.contribution_status_id = 1 and 
    c.is_test != 1 and 
    @solicitation_type = 'DM' 
  on duplicate key update pile = 'Foundation';
    
/* has any grants --> "Foundation" */ 
insert into mailing_pile select distinct 
    cb.bundle_id,
    'Foundation' as pile
  from civicrm_grant g 
  join contact_bundle cb using (contact_id)
  where @solicitation_type = 'DM' 
  on duplicate key update pile = 'Foundation';
  
  


/* ====================================================================== */
/*                      received_dm                                       */
/* ====================================================================== */

drop temporary table if exists received_dm; 
create temporary table received_dm like simple_bundle_table; 
insert into received_dm select distinct cb.bundle_id
  from civicrm_activity act
  join civicrm_activity_contact ac on 
    ac.activity_id = act.id and 
    ac.record_type_id in (2,3) /* by, with */ 
  join contact_bundle cb on cb.contact_id = ac.contact_id
  where 
    activity_type_id = 31 and 
    subject like 'DM%' and 
    activity_date_time 
      between @now - interval 2 month  and  @now + interval 2 month; 


/* ====================================================================== */
/*                      giving_age                                        */
/* ====================================================================== */
  
drop temporary table if exists giving_age; 
create temporary table giving_age (
  bundle_id int(10), 
  age int(2), 
  unique index(bundle_id) ); 
insert into giving_age select 
    bundle_id,
    floor(max(ybn)) as age 
  from contrib_worksheet cw
  join bundle on bundle.id = cw.bundle_id
  where 
    cw.ws > 0 and 
    cw.cid is not null and 
    bundle.is_chosen = 1
  group by bundle_id;

/* ====================================================================== */
/*                      recurring_summary                                 */
/* ====================================================================== */
  
drop temporary table if exists recurring_summary; 
create temporary table recurring_summary like simple_bundle_summary_table; 
insert into recurring_summary select 
    cb.bundle_id, 
    concat(
      group_concat( 
        concat_ws(' ',
          ndw.marker,
          'AUTO-PAY',
          concat('$',format(rec.amount,0)),
          'per',rec.frequency_unit, 
          'from',date_format(rec.start_date, '%Y-%b'),
          concat('to ',date_format(coalesce(rec.end_date, rec.cancel_date),'%Y-%b')) )
        order by rec.start_date desc
        separator '\n'
      ),
      '\n\n' ) as summ
  from civicrm_contribution_recur rec
  join name_detail_worksheet ndw on ndw.contact_id = rec.contact_id 
  join contact_bundle cb on cb.contact_id = rec.contact_id 
  where 
    rec.contribution_status_id in (1,3,4,5) and 
    rec.is_test = 0
  group by cb.bundle_id;
  

/* ====================================================================== */
/*                      pledge_summary                                 */
/* ====================================================================== */

drop temporary table if exists pledge_summary; 
create temporary table pledge_summary like simple_bundle_summary_table; 
insert into pledge_summary select 
    cb.bundle_id, 
    concat(
      group_concat( 
        concat_ws(' ',
          ndw.marker,
          'PLEDGE',
          concat('$',format(pledge.original_installment_amount,0)),
          'per',pledge.frequency_unit, 
          'for',pledge.installments, concat(pledge.frequency_unit,'s'), 
          'from',date_format(pledge.start_date, '%Y-%b') )
        order by pledge.start_date desc
        separator '\n'
      ),
      '\n\n' ) as summ
  from civicrm_pledge pledge
  join name_detail_worksheet ndw on ndw.contact_id = pledge.contact_id
  join contact_bundle cb on cb.contact_id = pledge.contact_id 
  where 
    pledge.is_test = 0 and 
    pledge.installments > 1
  group by cb.bundle_id;



/* ====================================================================== */
/*                      phone_summary                                     */
/* ====================================================================== */
  

drop temporary table if exists phone_worksheet; 
create temporary table phone_worksheet (
  bundle_id int(10), 
  phone char(20), 
  marker char(5) character set utf8,
  score bigint(12), 
  index(bundle_id), 
  index(phone), 
  index(score) ); 
insert into phone_worksheet select 
  ndw.bundle_id,
  cp.phone_compare as phone, 
  ndw.marker, 
  1000000000*(100-ndw.ordinal) + cp.priority as score
from name_detail_worksheet ndw
join contact_phones cp on cp.contact_id = ndw.contact_id
order by ndw.bundle_id, phone_compare, score desc;


drop temporary table if exists bundle_phones; 
create temporary table bundle_phones (
  bundle_id int(10), 
  phone char(20), 
  markers char(5) character set utf8,
  score bigint(12), 
  index(bundle_id) ); 
insert into bundle_phones select 
  bundle_id, 
  phone, 
  group_concat(distinct marker order by marker separator '') as markers,
  max(score) as score 
from phone_worksheet
group by bundle_id, phone; 


drop temporary table if exists phone_summary; 
create temporary table phone_summary (
  bundle_id int(10), 
  summ text character set utf8,
  num int(2), 
  unique index(bundle_id), 
  index(num) );
insert into phone_summary select 
    bundle_id, 
    group_concat(
      concat_ws('  from ', phone, markers)
      order by score desc
      separator '\n' ) as summ,
    count(*) as num
  from bundle_phones
  group by bundle_id; 


/* ====================================================================== */
/*                      pat_note_summary                                  */
/* ====================================================================== */
  
drop temporary table if exists pat_note_summary; 
create temporary table pat_note_summary like simple_bundle_summary_table; 
insert into pat_note_summary select 
  ndw.bundle_id, 
  group_concat( 
    concat_ws(' ',
      marker,
      subject,
      note ) 
    order by coalesce(modified_date,'2008-01-01') desc, note.id desc
    separator '\n\n' ) summ
from civicrm_note note
join name_detail_worksheet ndw on ndw.contact_id = note.entity_id
where 
  note.entity_table = 'civicrm_contact' and 
  note.subject like '%PAT%' 
group by ndw.bundle_id; 


/* ====================================================================== */
/*                      note_summary                                      */
/* ====================================================================== */

drop temporary table if exists note_summary; 
create temporary table note_summary like simple_bundle_summary_table; 
insert into note_summary select 
  ndw.bundle_id, 
  group_concat( 
    concat_ws(' ', marker, note ) 
    order by coalesce(modified_date,'2008-01-01') desc, note.id desc
    separator '\n\n' ) summ
from civicrm_note note
join name_detail_worksheet ndw on ndw.contact_id = note.entity_id
where 
  note.entity_table = 'civicrm_contact' and 
  note.subject not like '%PAT%' 
group by ndw.bundle_id; 

/* ====================================================================== */
/*                      bat_summary                                       */
/* ====================================================================== */


drop temporary table if exists bat_contact_summary;
create temporary table bat_contact_summary (
  bundle_id int(10), 
  marker char(5) character set utf8, 
  bats char(150),
  index(bundle_id) ); 
insert into bat_contact_summary select
    ndw.bundle_id, 
    ndw.marker, 
    if(count(*) > 4,
      concat(
        count(*), 'x between ',
        min(year(event.start_date) ), ' and ', 
        max(year(event.start_date) ) ),
      group_concat(
        distinct year(event.start_date) 
        order by start_date 
        separator ', ')
    ) as bats
  from name_detail_worksheet ndw
  join civicrm_participant part on part.contact_id = ndw.contact_id 
  join civicrm_event event on event.id = part.event_id
  where 
    event_type_id = 1 and /* BAT */ 
    is_test != 1 and 
    part.role_id in (1,5) and  /* rider, non-attending-fundraiser */ 
    part.status_id in (1,2) 
  group by ndw.bundle_id, ndw.contact_id;


drop temporary table if exists bat_summary;
create temporary table bat_summary like simple_bundle_summary_table;
insert into bat_summary select 
    bundle_id, 
    group_concat( 
      concat(
        coalesce(concat(markers, ': '),''), 
        bats )
      order by markers
      separator '  ' ) as summ
  from (
    select 
      bundle_id,
      bats, 
      group_concat(marker order by marker separator '') as markers
    from bat_contact_summary
    group by bundle_id, bats 
    ) b
  group by bundle_id; 



/* ====================================================================== */
/*                      address_summary                                   */
/* ====================================================================== */
  
drop temporary table if exists address_summary;
create temporary table address_summary like simple_bundle_summary_table;
insert into address_summary select 
    bundle.id,
    coalesce(
      concat(
        "☐ ", 
        address.street_address,
        coalesce(concat(' ',address.supplemental_address_1),''), ', ',
        address.city, ', ',
        state.abbreviation, ', ', 
        coalesce(address.postal_code,'')
      ), 'NO ADDRESS ON RECORD! ASK FOR ONE!'
    ) as summ
  from bundle
  left join bundle_address ba on ba.bundle_id = bundle.id
  left join civicrm_address address on address.id = ba.address_id
  left join civicrm_state_province state on address.state_province_id = state.id
  where bundle.is_chosen = 1; 


/* ====================================================================== */
/*                      email_summary                                     */
/* ====================================================================== */


/* valid email addresses */
drop table if exists valid_emails;
create table valid_emails (
  email_id int(10) not null,
  contact_id int(10), 
  unique index(email_id),
  index(contact_id) );
insert into valid_emails 
  select email.id, email.contact_id 
  from civicrm_email email
  join chosen_contacts cc on cc.contact_id = email.contact_id /* +performance */ 
  left join civicrm_location_type location on 
    location.id = email.location_type_id
  where location.name not like 'NoLongerValid%';

/* all possible emails for a contact */
drop table if exists contact_emails;
create table contact_emails (
  contact_id int(10) not null,
  email_id int(10) not null,
  email char(150) not null,
  priority int(10),
  index(contact_id),
  index(email_id),
  index(email),
  unique index(priority) );
insert into contact_emails
  select
      e.contact_id,
      e.id as email_id,
      e.email as email_compare,
      is_primary*10000000+e.id as priority 
    from civicrm_email e
    join valid_emails ve on ve.email_id = e.id
    where e.contact_id > 0; 


drop temporary table if exists email_worksheet; 
create temporary table email_worksheet (
  bundle_id int(10), 
  email char(150), 
  marker char(5) character set utf8,
  score bigint(12), 
  index(bundle_id), 
  index(email), 
  index(score) ); 
insert into email_worksheet select 
  ndw.bundle_id,
  ce.email, 
  ndw.marker, 
  1000000000*(100-ndw.ordinal) + ce.priority as score
from name_detail_worksheet ndw
join contact_emails ce on ce.contact_id = ndw.contact_id
order by ndw.bundle_id, email, score desc;


drop temporary table if exists bundle_emails; 
create temporary table bundle_emails (
  bundle_id int(10), 
  email char(150), 
  markers char(5) character set utf8,
  score bigint(12), 
  index(bundle_id) ); 
insert into bundle_emails select 
  bundle_id, 
  email, 
  group_concat(distinct marker order by marker separator '') as markers,
  max(score) as score 
from email_worksheet
group by bundle_id, email; 


drop temporary table if exists email_summary; 
create temporary table email_summary (
  bundle_id int(10), 
  summ text character set utf8,
  num int(2), 
  unique index(bundle_id), 
  index(num) );
insert into email_summary select 
    bundle.id, 
    coalesce(
      group_concat(
        concat(
          "☐ ",
          coalesce(concat(be.markers,':'),''), 
          email )
        order by be.score desc
        separator '  ' 
        ),
      'NO EMAIL ON RECORD! ASK FOR ONE!'
      ) as summ,
    count(*) as num
  from bundle
  left join bundle_emails be on be.bundle_id = bundle.id 
  group by bundle.id; 


/* ====================================================================== */
/*                      bundle_contact_ids                                */
/* ====================================================================== */


drop temporary table if exists bundle_contact_ids; 
create temporary table bundle_contact_ids (
  bundle_id int(10), 
  contact_ids char(200), 
  unique index(bundle_id) ); 
insert into bundle_contact_ids select 
    bundle_id,
    group_concat(contact_id order by contact_id)
  from contact_bundle
  join chosen_contacts using (contact_id) /* for performance */ 
  group by bundle_id; 
  

/**************************************************************************/
/**************************************************************************/
/***                                                                    ***/
/***                    mailing results                                 ***/
/***                                                                    ***/
/**************************************************************************/
/**************************************************************************/



drop table if exists mailing; 
create table mailing (
    primary_contact_id int(10),
    all_contact_ids char(200),
    bundle_id int(10),
    name char(200),
    address1 char(200),
    address2 char(200),
    city char(100),
    state char(10),
    zip char(20),
    pile char(50),
    thanks char(100),
    ask_amount decimal(7,2), 
    likelihood double, 
    priority double, 
    is_fresh int(1), 
    unique index(primary_contact_id), 
    unique index(bundle_id), 
    index(ask_amount), 
    index(likelihood), 
    index(priority),
    index(is_fresh) ); 
insert into mailing select 
  bundle_primary_contact.contact_id as primary_contact_id,
  bundle_contact_ids.contact_ids as all_contact_ids,
  bundle.id as bundle_id,
  bundle_name.name,  
  address.street_address as address1,
  address.supplemental_address_1 as address2,
  address.city as city,
  state.abbreviation as state,
  concat(
    coalesce(address.postal_code,''),
    coalesce(concat('-',address.postal_code_suffix),'')
    ) as zip,
  coalesce(mailing_pile.pile, 'Normal') as pile,
  coalesce(special_thanks.thanks, '') as thanks,
  bundle.aa_raw as ask_amount, 
  bundle.likelihood, 
  bundle.priority, 
  bundle.is_fresh
from bundle 
join bundle_name                       on bundle_name.bundle_id = bundle.id 
join bundle_contact_ids         on bundle_contact_ids.bundle_id = bundle.id
join bundle_primary_contact on bundle_primary_contact.bundle_id = bundle.id
left join mailing_pile                on mailing_pile.bundle_id = bundle.id
left join special_thanks            on special_thanks.bundle_id = bundle.id
join bundle_address                 on bundle_address.bundle_id = bundle.id
join civicrm_address address on address.id = bundle_address.address_id 
join civicrm_state_province state on address.state_province_id = state.id
where 
  bundle.is_chosen = 1 and 
  @solicitation_type = 'DM' 
order by pile, thanks, priority desc;





/**************************************************************************/
/**************************************************************************/
/***                                                                    ***/
/***                    PAT results                                     ***/
/***                                                                    ***/
/**************************************************************************/
/**************************************************************************/


drop table if exists pat; 
create table pat (
  page             int(6)    auto_increment,
  print_group      char(10)  not null,
  pcid             int(10), 
  name             char(150) not null, 
  contacts         text character set utf8 not null,
  bundle_id        int(10)   not null,
  all_contact_ids  char(100) not null,
  aa_raw           double    not null,
  ask              char(15)  not null,
  likelihood       double    not null,
  lh               char(15)  not null,
  priority         double    not null,
  p                char(15)  not null,
  difficulty       double    not null,
  pile             char(5)   not null,
  assignment       char(100) not null,
  ca               int(2)    not null,
  thanks           char(200) not null,
  dm               char(10)  not null,
  y                int(2)    not null,
  recurring        text character set utf8 not null,
  pledges          text character set utf8 not null, 
  contribs         text character set utf8 not null,
  phones           text character set utf8 not null,
  time_diff        char(100), 
  pat_notes        text character set utf8 not null,
  notes            text character set utf8 not null,
  bat              text character set utf8 not null,
  address          text character set utf8 not null,
  emails           text character set utf8 not null,
  quant            int(2) not null,
  `year`           int(4) not null, 
  primary key(page), 
  index(print_group),
  unique index(pcid), 
  unique index(bundle_id), 
  index(aa_raw), 
  index(ask),
  index(likelihood),
  index(priority),
  index(difficulty),
  index(pile),
  index(assignment),
  index(ca),
  index(quant) ) auto_increment=1;

insert into pat select 
  
  null as page, 
  
  if(length(special_thanks.thanks)>0,'THX',bundle.priority_level) as print_group,
  
  bundle_primary_contact.contact_id as primary_contact_id,
  
  coalesce(bundle_name.name,''), 
  
  coalesce(name_summary.summ,'') as contacts,
  
  bundle.id as bundle_id,
  
  bundle_contact_ids.contact_ids as all_contact_ids,
  
  bundle.aa_raw, 
  
  format(bundle.aa_round,0) as ask,
  
  bundle.likelihood, 
  
  concat(format(100*bundle.likelihood,0),'%') as lh, 
  
  bundle.priority, 
  
  format(bundle.priority,4) as p, 
  
  bundle.difficulty, 
  
  bundle.pile,
  
  coalesce(special_thanks.thanks, bundle.pile) as assignment,
  
  case priority_level 
    when 'A' then 3
    when 'B' then 3
    when 'C' then 2 
    when 'D' then 2
    when 'E' then 2
    else 1
    end as ca, 
  
  if(length(special_thanks.thanks) > 0, 
    concat('Needs to be called by: ', special_thanks.thanks), 
    '') as thanks,
  
  if(received_dm.bundle_id is null, 'NO', 'YES') as dm, 
  
  coalesce(giving_age.age,'') as y, 
  
  coalesce(recurring_summary.summ,'') as recurring, 
  
  coalesce(pledge_summary.summ,'') as pledges, 
  
  coalesce(contrib_summary.summ,'') as contribs, 
  
  coalesce(phone_summary.summ,'') as phones, 
  
  coalesce(time_zone_summary.summ,'') as time_diff, 
  
  coalesce(pat_note_summary.summ,'') as pat_notes,
  
  coalesce(note_summary.summ,'') as notes,
  
  coalesce(bat_summary.summ,'') as bat_rides, 
  
  coalesce(address_summary.summ,'') as address, 
  
  coalesce(email_summary.summ,'') as emails, 
  
  contacts_displayed.quant,
  
  year(@now) as `year`

from bundle 
left join bundle_primary_contact on bundle_primary_contact.bundle_id = bundle.id
left join bundle_name                       on bundle_name.bundle_id = bundle.id
left join name_summary                     on name_summary.bundle_id = bundle.id
left join bundle_contact_ids         on bundle_contact_ids.bundle_id = bundle.id
left join special_thanks                 on special_thanks.bundle_id = bundle.id
left join received_dm                       on received_dm.bundle_id = bundle.id
left join giving_age                         on giving_age.bundle_id = bundle.id
left join recurring_summary           on recurring_summary.bundle_id = bundle.id
left join pledge_summary                 on pledge_summary.bundle_id = bundle.id
left join contrib_summary               on contrib_summary.bundle_id = bundle.id
left join phone_summary                   on phone_summary.bundle_id = bundle.id
left join time_zone_summary           on time_zone_summary.bundle_id = bundle.id
left join pat_note_summary             on pat_note_summary.bundle_id = bundle.id
left join note_summary                     on note_summary.bundle_id = bundle.id
left join bat_summary                       on bat_summary.bundle_id = bundle.id
left join address_summary               on address_summary.bundle_id = bundle.id
left join email_summary                   on email_summary.bundle_id = bundle.id
left join contacts_displayed         on contacts_displayed.bundle_id = bundle.id
where bundle.is_chosen = 1
order by thanks desc, pile, quant desc, priority desc, difficulty; 







/**************************************************************************/
/**************************************************************************/
/***                                                                    ***/
/***                    Clean up                                        ***/
/***                                                                    ***/
/**************************************************************************/
/**************************************************************************/



/*  

Drop permanent tables created in this script 

grep "create table" QFAP.sql | sed 's/create/drop/g' | sed 's/ (/;/g' | tac

drop table if exists round_amounts;
drop table if exists contrib_worksheet;
drop table if exists contact_bundle;
drop table if exists bundle;
drop table if exists graph_node;
drop table if exists node_edge_bidirectional;
drop table if exists graph_edge;
drop table if exists connected_contacts; 
drop table if exists all_contacts;
drop table if exists exclude;
drop table if exists exclude_situation; 
drop table if exists exclude_strategy;
drop table if exists contact_addresses;
drop table if exists contact_phones;
drop table if exists valid_phones;
drop table if exists valid_relationships;
drop table if exists qualified_relationship_types;
drop table if exists valid_contacts;


*/


/* TODO there is a bunch of stuff in here that doesn't need to run for the DM. 
pull this out or add conditions to speed up the DM search */ 


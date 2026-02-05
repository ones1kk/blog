---
title: "성능 개선 전략: 인덱스, 역정규화, 비트맵 설계"
slug: "------"
date: "2026-01-27"
tags: ["devlog"]
status: "draft" # draft | published
summary: ""
cover: "./assets/cover.png"
---

# 성능 개선 전략: 인덱스, 역정규화, 비트맵 설계

# 들어가기 전 

성능 개선을 이야기할 때 가장 흔하게 등장하는 단어는 인덱스다.
쿼리가 느리면 인덱스를 추가하고 그래도 느리면 인덱스를 하나 더 추가한다.
하지만 실무에서는 인덱스를 아무리 추가해도 성능이 거의 개선되지 않는 경우가 분명히 있을 뿐더러 오히려 무분별한 인덱스 추가는 쓰기 성능 저하, 저장 공간 증가, 인덱스 유지·관리 비용 상승 같은 부작용을 낳을 수 있다. 

<br> 

이 글은 그런 상황에서 출발한다.
호텔을 검색할 때 전형적인 읽기 중심 도메인을 기준으로 정규화된 모델이 왜 느려지는지 그 문제를 해결하기 위해 왜 역정규화를 먼저 선택하게 되는지 그 이후 인덱스와 비트맵 설계가 어떤 역할을 맡게 되는지를 순서대로 정리한다.

<br> 

핵심은 "어떤 기법이 빠르다"가 아니라 **"어떤 문제에 어떤 순서로 접근해야 하는가"** 다.


# 1. 정규화된 모델은 왜 느려지는가

정규화는 모델의 논리적 구조를 표현하고 중복을 제거하며 변경을 한 곳에서 통제할 수 있게 만든다. 호텔이 도시를 참조하고 호텔이 시설/정책/이미지를 가진다는 사실을 테이블과 외래키로 표현하는 일은 자연스럽고 건강하다. 

하지만 논리적으로 잘 구성된 모델이 항상 빠르게 동작하는 것은 아니다. 정확히는 “논리적 올바름”과 “물리적 실행 비용”은 비례하지 않는다. 정규화된 모델 위에서 특정 유형의 조회가 수행될 때 데이터는 조인
과정에서 폭발적으로 늘어나고(fan-out) 이 폭발은 인덱스가 해결해주지 못하는 병목을 만든다. 인덱스는 접근 경로를 최적화할 뿐이지 조인으로 생성되는 중간 결과(row의 개수 자체)를 없애주지 못하기 때문이다.


# 2. 스키마 생성 


호텔 검색 도메인은 겉으로 보기에는 단순하다.
도시를 선택하고 몇 가지 필터를 고른 뒤 호텔 목록을 조회한다.
하지만 실제 서비스에서 이 조회는 다음과 같은 특징을 가진다.

<br> 

호텔은 수십만 단위로 존재한다.
시설, 정책, 이미지 같은 부가 정보는 모두 1:N 관계로 분리되어 있다.
검색 조건은 대부분 optional이며 조합이 자유롭다.
읽기 트래픽은 매우 높고 쓰기는 대부분 배치로 처리된다.

<br> 
이 조건에서 가장 자연스럽게 시작하는 모델은 정규화다.
호텔, 시설, 정책, 이미지를 각각 테이블로 분리하고 관계로 연결한다.

<br> 

아래는 mysql 기준의 스키마다.

<br> 

```sql
drop table if exists hotel_image;
drop table if exists hotel_policy;
drop table if exists hotel_facility;
drop table if exists policy;
drop table if exists facility;
drop table if exists hotel;
drop table if exists city;

create table city (
    city_id bigint primary key,
    city_name varchar(100) not null
) engine=innodb;

create table hotel (
    hotel_id bigint primary key,
    city_id bigint not null,
    hotel_name varchar(200) not null,
    status varchar(20) not null,
    rating decimal(3,2) not null,
    lat decimal(10,6) null,
    lng decimal(10,6) null,
    constraint fk_hotel_city foreign key (city_id) references city(city_id)
) engine=innodb;

create table facility (
    facility_id bigint primary key,
    facility_name varchar(50) not null
) engine=innodb;

create table policy (
    policy_id bigint primary key,
    policy_code varchar(50) not null
) engine=innodb;

create table hotel_facility (
    hotel_id bigint not null,
    facility_id bigint not null,
    primary key (hotel_id, facility_id),
    constraint fk_hf_hotel foreign key (hotel_id) references hotel(hotel_id),
    constraint fk_hf_facility foreign key (facility_id) references facility(facility_id)
) engine=innodb;

create table hotel_policy (
    hotel_id bigint not null,
    policy_id bigint not null,
    primary key (hotel_id, policy_id),
    constraint fk_hp_hotel foreign key (hotel_id) references hotel(hotel_id),
    constraint fk_hp_policy foreign key (policy_id) references policy(policy_id)
) engine=innodb;

create table hotel_image (
    hotel_id bigint not null,
    image_seq int not null,
    image_url varchar(400) not null,
    is_primary tinyint not null,
    primary key (hotel_id, image_seq),
    constraint fk_hi_hotel foreign key (hotel_id) references hotel(hotel_id)
) engine=innodb;

```

<br>

# 3. 데이터 생성

여기에 테스트를 위한 “합리적인 대용량”을 만들어보자.

아래는 “도시 100, 호텔 300,000, 시설 16, 정책 32, 매핑 다량”을 만드는 스크립트다.

<br> 


```sql
delimiter $$

drop procedure if exists seed_data $$
create procedure seed_data(
    in p_city_count int,
    in p_hotel_count int
)
begin
    /*
      digits 6개 → 0 ~ 999,999 (1,000,000 rows)
      where n < p_hotel_count 로 정확히 잘라 사용
    */

    /* city */
insert into city(city_id, city_name)
select
    n + 1,
    concat('city_', n + 1)
from (
         select
             d0.d
                 + d1.d * 10
                 + d2.d * 100
                 + d3.d * 1000
                 + d4.d * 10000
                 + d5.d * 100000 as n
         from
             (select 0 d union all select 1 union all select 2 union all select 3 union all select 4
              union all select 5 union all select 6 union all select 7 union all select 8 union all select 9) d0
                 cross join
             (select 0 d union all select 1 union all select 2 union all select 3 union all select 4
              union all select 5 union all select 6 union all select 7 union all select 8 union all select 9) d1
                 cross join
             (select 0 d union all select 1 union all select 2 union all select 3 union all select 4
              union all select 5 union all select 6 union all select 7 union all select 8 union all select 9) d2
                 cross join
             (select 0 d union all select 1 union all select 2 union all select 3 union all select 4
              union all select 5 union all select 6 union all select 7 union all select 8 union all select 9) d3
                 cross join
             (select 0 d union all select 1 union all select 2 union all select 3 union all select 4
              union all select 5 union all select 6 union all select 7 union all select 8 union all select 9) d4
                 cross join
             (select 0 d union all select 1 union all select 2 union all select 3 union all select 4
              union all select 5 union all select 6 union all select 7 union all select 8 union all select 9) d5
     ) nums
where n < p_city_count;

/* facility (16) */
insert into facility(facility_id, facility_name) values
                                                     (1,'wifi'),(2,'parking'),(3,'pool'),(4,'gym'),
                                                     (5,'spa'),(6,'restaurant'),(7,'bar'),(8,'laundry'),
                                                     (9,'breakfast'),(10,'aircon'),(11,'pet'),(12,'smoking'),
                                                     (13,'elevator'),(14,'wheelchair'),(15,'kitchen'),(16,'tv');

/* policy (32) */
insert into policy(policy_id, policy_code)
select
    n + 1,
    concat('policy_', n + 1)
from (
         select
             d0.d + d1.d * 10 as n
         from
             (select 0 d union all select 1 union all select 2 union all select 3 union all select 4
              union all select 5 union all select 6 union all select 7 union all select 8 union all select 9) d0
                 cross join
             (select 0 d union all select 1 union all select 2 union all select 3 union all select 4
              union all select 5 union all select 6 union all select 7 union all select 8 union all select 9) d1
     ) nums
where n < 32;

/* hotel (300,000 보장) */
insert into hotel(
    hotel_id, city_id, hotel_name, status, rating, lat, lng
)
select
    n + 1,
    ((n + 1) % p_city_count) + 1,
    concat('hotel_', n + 1),
    if((n + 1) % 10 = 0, 'inactive', 'active'),
    round(1.0 + (rand() * 4.0), 2), -- rating 주기 충돌 제거
    ((n + 1) % 900000) / 10000,
    ((n + 1) % 1800000) / 10000
from (
    select
    d0.d
    + d1.d * 10
    + d2.d * 100
    + d3.d * 1000
    + d4.d * 10000
    + d5.d * 100000 as n
    from
    (select 0 d union all select 1 union all select 2 union all select 3 union all select 4
    union all select 5 union all select 6 union all select 7 union all select 8 union all select 9) d0
    cross join
    (select 0 d union all select 1 union all select 2 union all select 3 union all select 4
    union all select 5 union all select 6 union all select 7 union all select 8 union all select 9) d1
    cross join
    (select 0 d union all select 1 union all select 2 union all select 3 union all select 4
    union all select 5 union all select 6 union all select 7 union all select 8 union all select 9) d2
    cross join
    (select 0 d union all select 1 union all select 2 union all select 3 union all select 4
    union all select 5 union all select 6 union all select 7 union all select 8 union all select 9) d3
    cross join
    (select 0 d union all select 1 union all select 2 union all select 3 union all select 4
    union all select 5 union all select 6 union all select 7 union all select 8 union all select 9) d4
    cross join
    (select 0 d union all select 1 union all select 2 union all select 3 union all select 4
    union all select 5 union all select 6 union all select 7 union all select 8 union all select 9) d5
    ) nums
where n < p_hotel_count;

end $$

delimiter ;

call seed_data(100, 300000);
```

<br>

이제 매핑 테이블을 채워야하는데 데이터의 현실성을 확보하기 위해 매핑 데이터의 분포는 의도적으로 “중간 선택도” 영역에 위치하도록 구성했다. 
여기서 중간 선택도란 특정 조건이 전체 데이터의 극히 일부(예: 1~5%)만을 걸러내지도 않고 그렇다고 대부분(예: 80~90%)을 그대로 통과시키지도 않는 상태를 의미한다. 
이 글에서는 시설, 정책과 같은 검색 조건이 전체 호텔 집합의 약 30~50% 수준을 통과하도록 분포를 설계했다. 

<br> 

지피티를 통해 알아보니 선택도가 지나치게 낮으면(희귀 조건) 옵티마이저는 인덱스를 통해 매우 작은 후보 집합을 빠르게 만들 수 있고 fan-out 문제는 표면화되지 않고 반대로 선택도가 지나치게 높으면(보편 조건) 조건 자체가 거의 필터 역할을 하지 못해 전체 스캔에 가까운 실행 계획으로 수렴한다고 한다. 

<br> 

결과적으로 순간 중간 결과가 급격히 팽창함으로써 단순한 인덱스 접근 비용이 아니라 조인 버퍼, 임시 테이블, group by 및 distinct 연산으로 이어지며 cpu, 메모리, i/o 비용을 동시에 증가시킨다. 

<br> 


```sql
delimiter $$

drop procedure if exists seed_fanout $$
create procedure seed_fanout()
begin
    -- hotel_facility
insert into hotel_facility (hotel_id, facility_id)
select
    h.hotel_id,
    ((h.hotel_id + f.seq) % 16) + 1
from hotel h
    join (
    select 1 as seq union all select 2 union all select 3 union all select 4 union all select 5
    union all select 6 union all select 7 union all select 8 union all select 9 union all select 10
    ) f;

-- hotel_policy
insert into hotel_policy (hotel_id, policy_id)
select
    h.hotel_id,
    ((h.hotel_id * 3 + p.seq) % 32) + 1
from hotel h
    join (
    select 1 as seq union all select 2 union all select 3
    union all select 4 union all select 5 union all select 6
    ) p;

-- hotel_image
insert into hotel_image (hotel_id, image_seq, image_url, is_primary)
select
    h.hotel_id,
    i.seq,
    concat('https://img/', h.hotel_id, '/', i.seq, '.jpg'),
    if(i.seq = 1, 1, 0)
from hotel h
         join (
    select 1 as seq union all select 2 union all select 3 union all select 4
    union all select 5 union all select 6 union all select 7 union all select 8
) i;
end $$

delimiter ;

call seed_fanout(300000);

```

# 4. 검색  쿼리 

이제 “정규화된 모델이 느려지는 문제”를 실제 쿼리로 확인해 보자. 여기서 핵심은 문제를 단순히 “인덱스가 없어서”라고 결론내리지 않는 것이다. 조인이 만드는 fan-out, 그리고 그 결과를 다시 정리하기 위한 distinct/집계 비용이 병목의 본체다.

<br> 

예시 조건은 현실적인 검색으로 잡았다.  
“도시=10, active, rating>=4.0, 시설 4개 중 2개 이상, 금연 정책”

<br> 

```sql
select distinct h.hotel_id,
                h.lat,
                h.lng,
                img.image_url
from hotel h
         join hotel_policy hp
              on hp.hotel_id = h.hotel_id
         join policy p
              on p.policy_id = hp.policy_id
                  and p.policy_code = 'policy_12'
         join hotel_facility hf
              on hf.hotel_id = h.hotel_id
         join facility f
              on f.facility_id = hf.facility_id
                  and f.facility_name in ('wifi', 'parking', 'pool', 'gym')
         left join hotel_image img
                   on img.hotel_id = h.hotel_id
                       and img.is_primary = 1
where h.city_id = 10
  and h.status = 'active'
  and h.rating >= 4.0;
```

<br>

실행 계획을 보면 성격이 명확해진다.

```sql
-> Table scan on <temporary>  (cost=14.8..14.8 rows=0.064) (actual time=1524..1525 rows=109 loops=1)
    -> Temporary table with deduplication  (cost=12.3..12.3 rows=0.064) (actual time=1524..1524 rows=109 loops=1)
        -> Nested loop left join  (cost=12.3 rows=0.064) (actual time=18.1..1524 rows=436 loops=1)
            -> Nested loop inner join  (cost=12.3 rows=0.064) (actual time=18..1518 rows=436 loops=1)
                -> Nested loop inner join  (cost=11.5 rows=1.28) (actual time=2.09..1304 rows=131250 loops=1)
                    -> Nested loop inner join  (cost=10.4 rows=3.2) (actual time=1.98..914 rows=562500 loops=1)
                        -> Nested loop inner join  (cost=6.89 rows=3.2) (actual time=0.598..16.2 rows=56250 loops=1)
                            -> Filter: (p.policy_code = 'policy_12')  (cost=3.45 rows=3.2) (actual time=0.162..0.169 rows=1 loops=1)
                                -> Table scan on p  (cost=3.45 rows=32) (actual time=0.143..0.149 rows=32 loops=1)
                            -> Covering index lookup on hp using fk_hp_policy (policy_id=p.policy_id)  (cost=1.01 rows=1) (actual time=0.43..13.6 rows=56250 loops=1)
                        -> Covering index lookup on hf using PRIMARY (hotel_id=hp.hotel_id)  (cost=1.03 rows=1) (actual time=0.0122..0.0154 rows=10 loops=56250)
                    -> Filter: (f.facility_name in ('wifi','parking','pool','gym'))  (cost=0.263 rows=0.4) (actual time=583e-6..600e-6 rows=0.233 loops=562500)
                        -> Single-row index lookup on f using PRIMARY (facility_id=hf.facility_id)  (cost=0.263 rows=1) (actual time=381e-6..403e-6 rows=1 loops=562500)
                -> Filter: ((h.city_id = 10) and (h.`status` = 'active') and (h.rating >= 4.00))  (cost=0.476 rows=0.05) (actual time=0.00155..0.00155 rows=0.00332 loops=131250)
                    -> Single-row index lookup on h using PRIMARY (hotel_id=hp.hotel_id)  (cost=0.476 rows=1) (actual time=0.00136..0.00138 rows=1 loops=131250)
            -> Filter: (img.is_primary = 1)  (cost=2.56 rows=1) (actual time=0.0119..0.0129 rows=1 loops=436)
                -> Index lookup on img using PRIMARY (hotel_id=hp.hotel_id)  (cost=2.56 rows=1) (actual time=0.0118..0.0125 rows=8 loops=436)
```

<br> 

SQL만 보면 자연스럽다. 하지만 실행 계획은 이 쿼리가 어떤 물리 연산을 강제하는지 보여준다.

<br> 

핵심은 **조인 순서와 fan-out**이다.  
옵티마이저는 “선택도가 높은 조건”부터 시작하고 싶지만 선택도가 높은 조건이 여러 테이블에 분산돼 있다.  
city/status/rating은 hotel에 policy_12는 policy/hotel_policy에 시설 조건은 facility/hotel_facility에 있다.  
어느 테이블부터 시작해도 다음 조인에서 팬아웃이 발생할 여지가 남는다.

<br>

그리고 중요한 건 **최종 결과 rows가 아니라 중간 결과가 얼마나 커지는지**다.  
호텔 하나가 policy 6개, facility 10개를 갖는 순간 단순 곱셈으로 60배의 row가 만들어진다.  
그 row들이 다시 left join image로 붙으면 lookup이 추가로 발생한다.  
인덱스가 있어도 “row를 만들어내는 비용”은 사라지지 않는다.

<br>

여기서 distinct가 등장한다.  
mysql은 distinct를 임시 테이블 + 중복제거(혹은 sort/unique)로 처리하는 경우가 많고 이 과정은 스트리밍을 포기하게 만든다.  
따라서 “distinct가 비싸다”가 결론이 아니라 **distinct를 강제한 원인이 fan-out 조인 구조**라는 점이 핵심이다.  
distinct는 증상이고 원인은 조인 구조다.

<br>

따라서 이 단계에서 우리가 확인해야 하는 건 **조인 구조가 만들어내는 중간 결과 폭발**이다.  
지금 현재로서는 병목이 distinct/임시테이블/정렬인지 조인 접근 경로인지가 흐려진다.



실행계획 기준 actual time은 약 1.52초였다. 조인 폭발과 distinct가 겹치면서 임시 테이블과 중복제거 비용이 그대로 드러나는 구간이며, 이후 비교의 기준점이 된다.

# 5. 쿼리 튜닝 

앞선 쿼리는 조인 순서가 어떻게 잡혀도 fan-out이 발생하는 구조였다. 따라서 1차 개선의 목표는 조인을 “더 잘” 하는 것이 아니라 조인 전에 fan-out을 먼저 접는 데 있다. 실무에서 흔히 쓰는 방식은 fan-out 테이블에서 hotel_id 후보군을 집합으로 만들고 그 결과에만 hotel을 붙이는 것이다. 이 방식은 정규화의 비용을 인정하되 모델을 바꾸기 전 단계에서 취할 수 있는 현실적인 최선에 가깝다.

구체적으로는 시설 조건과 정책 조건을 각각 hotel_id 집합으로 만든 뒤 교집합을 취한다. 그러면 중간 결과는 “호텔×정책×시설” 같은 곱 형태가 아니라 “후보 집합 간의 교차”로 바뀐다. 조인 폭발을 줄이는 대신 집계와 중복제거 비용을 감수하는 구조로 이동하는 셈이다.

```sql
select
    h.hotel_id,
    h.lat,
    h.lng,
    img.image_url
from hotel h
join (
    select
        hf.hotel_id
    from hotel_facility hf
    join facility f on hf.facility_id = f.facility_id
    where f.facility_name in ('wifi', 'parking', 'pool', 'gym')
    group by hf.hotel_id
    having count(distinct f.facility_name) >= 2
) hf2 on h.hotel_id = hf2.hotel_id
join (
    select
        hp.hotel_id
    from hotel_policy hp
    join policy p on hp.policy_id = p.policy_id
    where p.policy_code = 'policy_12'
    group by hp.hotel_id
) hp1 on h.hotel_id = hp1.hotel_id
left join hotel_image img
    on h.hotel_id = img.hotel_id
   and img.is_primary = 1
where h.city_id = 10
  and h.status = 'active'
  and h.rating >= 4.0;
```

explain analyze 결과를 보면 병목의 형태가 바뀐 것이 드러난다. fan-out 조인 폭발 대신, 후보군 생성 과정에서의 sort, group aggregate, count(distinct) 같은 집계 연산이 시간을 대부분 차지한다. 즉 조인을 피했다고 해서 비용이 사라지는 것이 아니라 비용의 형태가 집계와 정렬로 이동한 것이다.

이제 자연스럽게 “인덱스를 더 깔면 되지 않나?”라는 질문으로 넘어간다. 


실행계획 기준 actual time은 약 0.88초로 줄었다. 첫 번째 쿼리 대비 약 1.7배 개선이며, 조인 폭발이 집계/정렬 비용으로 이동했기 때문에 개선 폭이 제한적이라는 점이 함께 드러난다.


# 6. 인덱스 생성

인덱스는 정답처럼 깔면 안 된다. 병목이 group/sort로 이동한 순간 인덱스는 제한적으로만 도움이 된다. 따라서 실무에서 흔히 하는 수준까지만 제안하고 어디까지가 효과이고 어디부터가 한계인지 분명히 한다.

```sql
-- hotel: 조건 필터 후 id를 뽑아 join하는 구간만 보조
create index ix_hotel_city_status_rating on hotel (city_id, status, rating, hotel_id);

-- hotel_image: 대표 이미지를 빠르게 찾기
create index ix_hotel_image_primary on hotel_image (hotel_id, is_primary, image_seq);

-- hotel_policy: policy_id 기반 탐색 + hotel_id 묶기 패턴 지원
create index ix_hotel_policy_policy_hotel on hotel_policy (policy_id, hotel_id);
create index ix_hotel_policy_hotel on hotel_policy (hotel_id);

-- hotel_facility: facility_id 기반 탐색 + hotel_id group by 지원
create index ix_hotel_facility_facility_hotel on hotel_facility (facility_id, hotel_id);
create index ix_hotel_facility_hotel on hotel_facility (hotel_id);
```

이 인덱스들은 후보군을 만드는 과정에서의 접근 비용을 낮춰주지만, hf2의 group by hf.hotel_id와 count(distinct ...)를 완전히 제거하지는 못한다. 일부 경우 loose index scan 같은 최적화가 가능하더라도, distinct 카운트는 결국 중복제거를 필요로 하고 그 자체가 비용으로 남는다. 따라서 개선은 “조금 낫다” 수준에서 멈춘다. 이 사실이 바로 정규화 구조에서의 본질적인 비용을 보여준다. group/sort/materialize는 데이터 구조의 비용이고, 인덱스는 접근 경로의 비용이다.
인덱스는 접근 경로를 줄이는 데에는 도움을 주지만 집계와 중복제거 그 자체를 대체하지는 못한다.


<br> 

인덱스 적용 후 실행계획의 핵심 변화는 “접근 경로의 정돈”이다. hotel은 city/status/rating 조건으로 범위 스캔을 타고 진입하고 policy와 facility는 커버링 인덱스로 후보군을 뽑는다. 조인 폭발을 줄이기 위해 만든 서브쿼리의 의도는 유지되면서 접근 비용만 줄어든다.

하지만 병목의 형태 자체는 변하지 않는다. hf2와 hp1이 materialize 되면서 group aggregate, sort, count(distinct)가 여전히 시간을 대부분 먹는다. 조인 폭발이 집계/정렬 비용으로 바뀌었다는 관찰은 그대로이며 인덱스는 그 비용을 제거하지 못한다. 즉 인덱스는 경로를 줄일 수는 있어도 집계의 본질적인 비용은 대체하지 못한다.

아래는 인덱스 적용 후 실행계획의 핵심 부분이다.

```sql
-> Nested loop left join  (cost=98036 rows=0) (actual time=744..850 rows=109 loops=1)
    -> Nested loop inner join  (cost=21696 rows=0) (actual time=744..832 rows=109 loops=1)
        -> Nested loop inner join  (cost=2720 rows=0) (actual time=686..774 rows=579 loops=1)
            -> Index range scan on h using ix_hotel_city_status_rating over (city_id = 10 AND status = 'active' AND 4.00 <= rating), with index condition: ((h.city_id = 10) and (h.`status` = 'active') and (h.rating >= 4.00))  (cost=823 rows=759) (actual time=19.8..106 rows=759 loops=1)
            -> Covering index lookup on hf2 using <auto_key0> (hotel_id=h.hotel_id)  (cost=0.25..2.5 rows=10) (actual time=0.88..0.88 rows=0.763 loops=759)
                -> Materialize  (cost=0..0 rows=0) (actual time=666..666 rows=206250 loops=1)
                    -> Filter: (count(distinct facility.facility_name) >= 2)  (actual time=443..557 rows=206250 loops=1)
                        -> Group aggregate: count(distinct facility.facility_name)  (actual time=443..544 rows=243750 loops=1)
                            -> Sort: hf.hotel_id  (actual time=443..471 rows=750000 loops=1)
                                -> Stream results  (cost=132726 rows=1.28e+6) (actual time=3..210 rows=750000 loops=1)
                                    -> Nested loop inner join  (cost=132726 rows=1.28e+6) (actual time=2.99..147 rows=750000 loops=1)
                                        -> Filter: (f.facility_name in ('wifi','parking','pool','gym'))  (cost=1.85 rows=6.4) (actual time=0.358..0.392 rows=4 loops=1)
                                            -> Table scan on f  (cost=1.85 rows=16) (actual time=0.353..0.369 rows=16 loops=1)
                                        -> Covering index lookup on hf using ix_hotel_facility_facility_hotel (facility_id=f.facility_id)  (cost=3896 rows=199604) (actual time=1.26..29.4 rows=187500 loops=4)
        -> Covering index lookup on hp1 using <auto_key0> (hotel_id=h.hotel_id)  (cost=59483..59485 rows=10) (actual time=0.0999..0.1 rows=0.188 loops=579)
            -> Materialize  (cost=59483..59483 rows=187976) (actual time=57.2..57.2 rows=56250 loops=1)
                -> Table scan on <temporary>  (cost=38333..40685 rows=187976) (actual time=25.7..29.2 rows=56250 loops=1)
                    -> Temporary table with deduplication  (cost=38333..38333 rows=187976) (actual time=25.7..25.7 rows=56250 loops=1)
                        -> Nested loop inner join  (cost=19536 rows=187976) (actual time=2.7..12.2 rows=56250 loops=1)
                            -> Filter: (p.policy_code = 'policy_12')  (cost=3.45 rows=3.2) (actual time=0.0372..0.0434 rows=1 loops=1)
                                -> Table scan on p  (cost=3.45 rows=32) (actual time=0.0332..0.038 rows=32 loops=1)
                            -> Covering index lookup on hp using ix_hotel_policy_policy_hotel (policy_id=p.policy_id)  (cost=2065 rows=58742) (actual time=2.66..10 rows=56250 loops=1)
    -> Filter: (img.is_primary = 1)  (cost=1.01 rows=6.56) (actual time=0.16..0.169 rows=1 loops=109)
        -> Index lookup on img using PRIMARY (hotel_id=h.hotel_id)  (cost=1.01 rows=6.56) (actual time=0.159..0.169 rows=8 loops=109)
```


실행계획 기준 actual time은 약 0.85초다. 두 번째 쿼리 대비 약 1.04배 수준의 소폭 개선이며, 첫 번째 쿼리 대비로는 약 1.8배 개선이다. 접근 경로는 좋아졌지만 병목이 집계/정렬에 남아 있으므로 개선 폭은 제한적이다. 이 수치는 동일한 데이터와 동일한 조건에서 측정된 실행계획의 actual time을 기준으로 정리한 것이며, 캐시 상태나 데이터 분포에 따라 절대값은 달라질 수 있다.


# 7. 그렇다면 다음은? 

fan-out을 접는 방법 중 가장 즉각적인 방식은 EXISTS 기반의 세미조인이다. 아래 쿼리는 hotel을 먼저 후보로 좁힌 뒤, 정책/시설 조건을 EXISTS로 확인한다. 실행계획에서는 Nested loop semijoin이 형성되며, 중간 결과를 팽창시키지 않고 조건 만족 여부만 판정한다. 

<br> 

```sql
explain analyze
select
    h.hotel_id,
    h.lat,
    h.lng,
    img.image_url
from hotel h
         left join hotel_image img
                   on img.hotel_id = h.hotel_id
                       and img.is_primary = 1
where h.city_id = 10
  and h.status = 'active'
  and h.rating >= 4.0
  and exists (
    select 1
    from hotel_policy hp
             join policy p on p.policy_id = hp.policy_id
    where hp.hotel_id = h.hotel_id
      and p.policy_code = 'policy_12'
)
  and exists (
    select 1
    from hotel_facility hf
             join facility f on f.facility_id = hf.facility_id
    where hf.hotel_id = h.hotel_id
      and f.facility_name in ('wifi','parking','pool','gym')
);
```

<br> 

```sql
-> Nested loop left join  (cost=4559 rows=11635) (actual time=1.07..17.5 rows=109 loops=1)
    -> Nested loop semijoin  (cost=2635 rows=1774) (actual time=1.05..16.6 rows=109 loops=1)
        -> Nested loop semijoin  (cost=1687 rows=2916) (actual time=0.552..10.1 rows=579 loops=1)
            -> Index range scan on h using ix_hotel_city_status_rating over (city_id = 10 AND status = 'active' AND 4.00 <= rating), with index condition: ((h.city_id = 10) and (h.`status` = 'active') and (h.rating >= 4.00))  (cost=714 rows=759) (actual time=0.474..3.22 rows=759 loops=1)
            -> Nested loop inner join  (cost=1825 rows=3.84) (actual time=0.00883..0.00883 rows=0.763 loops=759)
                -> Covering index lookup on hf using PRIMARY (hotel_id=h.hotel_id)  (cost=0.899 rows=9.61) (actual time=0.00512..0.00549 rows=3.13 loops=759)
                -> Filter: (f.facility_name in ('wifi','parking','pool','gym'))  (cost=0.961 rows=0.4) (actual time=927e-6..927e-6 rows=0.243 loops=2379)
                    -> Single-row index lookup on f using PRIMARY (facility_id=hf.facility_id)  (cost=0.961 rows=1) (actual time=613e-6..635e-6 rows=1 loops=2379)
        -> Nested loop inner join  (cost=463 rows=0.608) (actual time=0.0111..0.0111 rows=0.188 loops=579)
            -> Covering index lookup on hp using ix_hotel_policy_hotel (hotel_id=h.hotel_id)  (cost=1.02 rows=6.08) (actual time=0.00401..0.0049 rows=5.62 loops=579)
            -> Filter: (p.policy_code = 'policy_12')  (cost=0.0608 rows=0.1) (actual time=986e-6..986e-6 rows=0.0335 loops=3256)
                -> Single-row index lookup on p using PRIMARY (policy_id=hp.policy_id)  (cost=0.0608 rows=1) (actual time=675e-6..705e-6 rows=1 loops=3256)
    -> Filter: (img.is_primary = 1)  (cost=1 rows=6.56) (actual time=0.00545..0.0079 rows=1 loops=109)
        -> Index lookup on img using PRIMARY (hotel_id=h.hotel_id)  (cost=1 rows=6.56) (actual time=0.00524..0.00727 rows=8 loops=109)
```

<br> 

이 구조에서는 distinct가 필요 없어지고 임시 테이블도 사라지며 실제 실행 시간은 약 17ms 수준으로 떨어진다.
이 정도 수치라면 조인 전략이 Nested loop라도 감당 가능한 수준이다. 

<br> 

문제는 일반화 가능성이다. 이 플랜이 성립하는 전제는 다음과 같이 정리된다. hotel 자체 조건(city/status/rating)의 선택도가 매우 높고, 그 조건이 항상 쿼리에 포함되며, 항상 먼저 적용 가능하고, 옵티마이저가 그 사실을 항상 알아차리며, 조건 조합이 크게 변하지 않아야 한다. 이 중 하나라도 깨지면 세미조인 플랜은 바로 이전의 조인 폭발 구조로 되돌아간다. 즉 이 성능은 “현재 데이터 분포와 현재 조건 조합에 최적화된 결과”일 뿐이며, 일반화 가능한 해결책이라고 보기 어렵다. 이 지점에서 역정규화 논의로 넘어간다.


# 8. 역정규화

앞선 단계까지의 튜닝은 모두 “정규화된 구조를 유지한 채 비용을 어떻게 우회할 것인가”에 대한 시도였다.
조인 순서를 바꾸고, fan-out을 접고, 인덱스를 정리하고, 세미조인을 활용했다.
하지만 이 모든 접근의 공통점은 fan-out이라는 구조적 문제를 제거하지는 못했다는 점이다.

<br> 

정규화 모델에서의 fan-out은 구현의 문제가 아니라 데이터 모델이 강제하는 연산 형태다.
호텔 하나가 여러 시설과 정책을 갖는다는 사실을 테이블로 분리해 표현하는 순간,
“호텔 × 시설 × 정책”이라는 곱셈 가능성은 물리적으로 존재하게 된다.
쿼리 튜닝은 이 곱셈을 덜 드러나게 만들 수는 있어도, 없애지는 못한다.

<br> 

이 지점에서 역정규화는 “성능을 조금 더 끌어내기 위한 트릭”이 아니라
비용을 런타임에서 설계 시점으로 이동시키는 선택이 된다. 


# 9. 무엇을 역정규화할 것인가 

역정규화에는 여러 선택지가 있다. 문자열 중복, boolean 컬럼 분해, json 컬럼, 집계 테이블 모두 가능한 해법이다. 그러나 이 글의 도메인처럼 조건의 종류가 많고, 조합이 자유롭고, 조회 트래픽이 압도적으로 높은 환경에서는 대부분의 기법이 특정 지점에서 구조적 한계를 드러낸다.
여러 방법 중 이 글에서는 비트맵을 예로 들어 진행할 것이며 이는 비트맵이 “가장 빠른 방법”이어서 선택된 것이 아니라, 비용의 위치와 형태를 가장 예측 가능하게 만들기 때문에 선택된다. 

<br> 


기본적으로 역정규화는 아무 것이나 합치는 작업이 아니며 핵심은 “조회 조건으로 반복 사용되며, fan-out의 직접적인 원인이 되는 정보”다.

이 글의 도메인에서 그 대상은 명확하다.

<br> 

- 시설 조건 (wifi, parking, pool, gym …)
- 정책 조건 (smoking, pet, age_limit …)

<br> 

이 두 조건은 공통적인 특징을 가진다.


<br> 

첫째, 값의 종류가 제한적이다. 시설은 수십 개, 정책은 많아야 수십 개 수준이다. 
둘째, 변경 빈도가 매우 낮다. 호텔 시설과 정책은 실시간으로 변하지 않는다. 
셋째, 조회 시에는 “존재 여부”만 중요하다. 조인된 row 자체가 필요하지 않다. 

즉, 이 데이터는 관계형 조인이 아니라 상태 표현에 가깝다.
그렇다면 이 상태를 굳이 N개의 row로 풀어둘 이유가 없다.

<br> 

# 10. 비트맵 역정규화

앞서 구현했던 요구사항과 조건들을 상기하며 시설과 정책을 각각 비트맵으로 압축해 hotel 테이블에 직접 포함시키는 작업을 진행해보도록 하자. 

<br> 

```sql
alter table hotel
    add column facility_bitmap bigint not null default 0,
    add column policy_bitmap bigint not null default 0;
```

<br> 


물론 비트맵을 hotel 테이블에 직접 포함시키는 방식은 가장 공격적인 형태의 역정규화다. 이 선택이 과해 보이는 이유는 “검색 상태”가 “도메인 엔티티”에 섞이기 때문이다.
하지만 이 글에서는 성능 개선을 위한 실험적 글이고 조회 트래픽이 압도적이고, 해당 상태가 hotel의 본질적 속성에 가깝다고 가정을 하고 진행을 한다.
만약 이 경계가 불편하다면 search_snapshot 같은 1:1 보조 테이블로 분리하는 방식이 가장 현실적인 타협안이 될 수 있을 것 같다. 

<br> 

추가된 비트맵 관련 컬럼들은 앞으로 아래와 같이 매핑될 예정이다. 

<br> 

```text
wifi        -> 1 << 0  (1)
parking     -> 1 << 1  (2)
pool        -> 1 << 2  (4)
gym         -> 1 << 3  (8)
spa         -> 1 << 4  (16)
...

```


<br> 

이제 역정규화 데이터를 적재해보자.

```sql
update hotel h
join (
    select
        hf.hotel_id,
        sum(1 << (hf.facility_id - 1)) as facility_mask
    from hotel_facility hf
    group by hf.hotel_id
) x on x.hotel_id = h.hotel_id
set h.facility_bitmap = x.facility_mask;

update hotel h
    join (
    select
    hp.hotel_id,
    sum(1 << (hp.policy_id - 1)) as policy_mask
    from hotel_policy hp
    group by hp.hotel_id
    ) x on x.hotel_id = h.hotel_id
    set h.policy_bitmap = x.policy_mask;

```

<br> 

이 비용도 상당히 큰 작업이지만 이 비용은 배치 시 한 번 발생한다.
반면 이전 구조의 fan-out 비용은 모든 검색 요청마다 반복 발생했다.

<br> 

# 11. 역정규화 이후 쿼리

역정규화 이후의 쿼리는 더 이상 “조인을 어떻게 구성할 것인가”를 고민하지 않는다.
핵심 조건들이 이미 hotel row 내부로 접혀 들어갔기 때문이다.

<br> 


시설과 정책 조건은 더 이상 fan-out 테이블을 탐색하지 않고,
단일 row에 저장된 상태 값에 대해 비트 연산으로 평가된다.
이로 인해 조인, 집계, distinct, 임시 테이블과 같은 연산이 전부 사라진다.


<br> 


```sql
select
    h.hotel_id,
    h.lat,
    h.lng,
    img.image_url
from hotel h
left join hotel_image img
    on img.hotel_id = h.hotel_id
   and img.is_primary = 1
where h.city_id = 10
  and h.status = 'active'
  and h.rating >= 4.0
  and (h.policy_bitmap & (1 << 11)) != 0
  and (
        (h.facility_bitmap & (1 << 0)) != 0
     or (h.facility_bitmap & (1 << 1)) != 0
     or (h.facility_bitmap & (1 << 2)) != 0
     or (h.facility_bitmap & (1 << 3)) != 0
  );

```

<br>

```sql
-> Nested loop left join  (cost=1600 rows=4978) (actual time=0.366..4.35 rows=109 loops=1)
    -> Filter: (((h.policy_bitmap & <cache>((1 << 11))) <> 0) and (((h.facility_bitmap & <cache>((1 << 0))) <> 0) or ((h.facility_bitmap & <cache>((1 << 1))) <> 0) or ((h.facility_bitmap & <cache>((1 << 2))) <> 0) or ((h.facility_bitmap & <cache>((1 << 3))) <> 0)))  (cost=342 rows=759) (actual time=0.342..3.37 rows=109 loops=1)
        -> Index range scan on h using ix_hotel_city_status_rating over (city_id = 10 AND status = 'active' AND 4.00 <= rating), with index condition: ((h.city_id = 10) and (h.`status` = 'active') and (h.rating >= 4.00))  (cost=342 rows=759) (actual time=0.331..3.29 rows=759 loops=1)
    -> Filter: (img.is_primary = 1)  (cost=1 rows=6.56) (actual time=0.00571..0.00868 rows=1 loops=109)
        -> Index lookup on img using PRIMARY (hotel_id=h.hotel_id)  (cost=1 rows=6.56) (actual time=0.00554..0.00802 rows=8 loops=109)

```

<br> 

이 쿼리의 전체 실행 시간은 약 4.35ms 수준이다.
초기 정규화 모델에서 fan-out과 distinct가 겹쳤던 쿼리의 실행 시간이 약 1.52초였던 것과 비교하면,
약 300배 이상 개선된 수치다.

<br> 

이 성능 차이는 인덱스를 더 잘 깔아서 얻은 결과가 아니다.
조인을 제거했고, 중간 결과를 만들지 않았으며,
모든 조건을 단일 row 내부에서 CPU 연산으로 처리하도록 구조를 바꾼 결과다.

<br> 

중요한 점은 이 성능이 특정 실행 계획이나 옵티마이저 판단에 의존하지 않는다는 사실이다.
조건 조합이 바뀌어도, 시설이나 정책 조건이 늘어나도,
쿼리는 동일한 형태로 평가된다.

<br> 

즉, 성능의 근거가 “운이 좋은 실행 계획”이 아니라
“데이터 표현 방식 자체”에 있다.

<br> 

# 마무리

이 글에서 살펴본 성능 개선 과정은 단순한 튜닝 사례가 아니다.
정규화 → 쿼리 튜닝 → 인덱스 추가 → 세미조인 → 역정규화로 이어지는 흐름은,
성능 문제가 어디까지가 SQL의 책임이고 어디서부터 모델링의 문제인지 보여준다.

<br> 

정규화는 논리적으로 올바른 모델을 만든다.
하지만 읽기 중심 도메인에서, 특히 fan-out이 구조적으로 발생하는 경우,
정규화는 성능 비용을 필연적으로 동반한다.
인덱스는 접근 경로를 최적화할 수는 있지만,
조인으로 생성되는 중간 결과 자체를 없애주지는 못한다.

<br> 

성능 문제를 만났을 때,
다음 인덱스를 고민하기 전에 한 번쯤은 이렇게 질문해볼 필요가 있다.

<br> 

“이 비용은 정말 쿼리의 문제인가,
아니면 데이터를 이렇게 표현하고 있기 때문에 발생하는 문제인가.”

<br> 




오탈자 및 오류 내용을 댓글 또는 메일로 알려주시면, 검토 후 조치하겠습니다.

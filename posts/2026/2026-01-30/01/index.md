---
title: "MySql의 조인 전략"
slug: "mysql--"
date: "2026-01-30"
tags: ["devlog"]
status: "draft" # draft | published
summary: ""
cover: "./assets/cover.png"
---

# MySql의 조인 전략


# 들어가기 전 


MySQL의 조인 전략을 이야기할 때 가장 흔한 오해는 “옵티마이저가 알아서 가장 빠른 조인을 선택해준다”는 믿음이다. 실제로는 그 반대에 가깝다. MySQL에서 조인 전략은 쿼리 문법에 의해 선택되지 않으며, 대부분의 경우 데이터의 형태와 분포가 어떤 전략을 강제한다.



이 글에서는 MySQL이 사용할 수 있는 조인 전략들을 하나씩 살펴보고, 각각의 전략이 어떤 데이터 포맷에서 의미를 가지는지, 그리고 그 상황에서 다른 전략을 선택하면 어떤 비용 차이가 발생하는지를 실행계획 관점에서 정리한다.
즉  먼저 의도적으로 특정한 데이터 분포를 만들고, 그 데이터 위에서 쿼리를 실행한 뒤, MySQL이 왜 그 조인 전략 말고는 선택할 수 없었는지를 실행계획을 근거로 설명한다. 이후 동일한 문제를 다른 전략으로 풀려고 할 때 비용 구조가 어떻게 바뀌는지를 비교한다.

이 글의 목적은 “조인 전략 나열”이 아님을 강조하고 싶다. 

이 글은 MySQL이 “어떤 조인을 선택했는가”를 설명하지 않는다.
대신 “왜 다른 조인은 선택지에 존재하지 않았는가”를 실행계획과 데이터 분포를 통해 추적한다.



# 1. Nested Loop Join

Nested Loop Join은 MySQL의 기본 조인 알고리즘이다. 실행 방식은 단순하다.

첫 번째 실험은 MySQL에서 Nested Loop Join이 가장 자연스럽게 선택되는 1:N 관계를 만든다. orders가 부모 테이블이고, order_item이 자식 테이블이다. 

<br> 

```sql
drop table if exists orders;
drop table if exists order_item;

create table orders (
    order_id bigint primary key,
    user_id bigint not null,
    order_status varchar(20) not null
) engine=innodb;

create table order_item (
    order_item_id bigint primary key,
    order_id bigint not null,
    product_id bigint not null,
    quantity int not null,
    constraint fk_order_item_order
        foreign key (order_id) references orders(order_id)
) engine=innodb;

create index ix_order_item_order_id on order_item(order_id);

```

<br>

데이터는 단순히 많이 넣지 않는다. 조인 전략을 관찰하려면 fan-out이 균등하지 않게 분포돼야 한다.

<br> 

```sql
insert into orders (order_id, user_id, order_status)
select
    n,
    n % 100,
    if(n % 5 = 0, 'cancelled', 'completed')
from (
    select
        d0.d + d1.d * 10 + d2.d * 100 + d3.d * 1000 as n
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
) t
where n between 1 and 10000;
```

<br> 

orders는 총 10,000건이다. 이 중 약 80%는 completed 상태다.

order_item은 일부 order에만 여러 row가 붙도록 만든다.

<br> 

```sql
insert into order_item (order_item_id, order_id, product_id, quantity)
select
    row_number() over (),
    o.order_id,
    (o.order_id + seq) % 500,
    1
from orders o
join (
    select 1 as seq union all select 2 union all select 3
    union all select 4 union all select 5
) s
on o.order_id % 3 = 0;

```

<br> 

이 결과로 약 1/3의 order만 평균 5개의 item을 가진다. fan-out은 존재하지만 전체적으로 폭발하지는 않는, Nested Loop가 아직 유효한 구조다.


이 구조에서 중요한 점은 조인 키(order_id)에 명확한 인덱스가 존재한다는 점이다. 이 사실 하나만으로도 MySQL은 Hash Join이나 Materialization보다 Nested Loop를 훨씬 선호하게 된다.

<br> 


## 쿼리 실행 및 분석 

```sql
explain analyze
select
    o.order_id,
    o.order_status,
    oi.product_id
from orders o
join order_item oi
    on oi.order_id = o.order_id
where o.order_status = 'completed';

```

<br> 

```sql
-> Nested loop inner join  (cost=1630 rows=877) (actual time=0.351..71.2 rows=13335 loops=1)
    -> Filter: (o.order_status = 'completed')  (cost=957 rows=877) (actual time=0.222..27.7 rows=8000 loops=1)
        -> Table scan on o  (cost=957 rows=8768) (actual time=0.211..25.1 rows=9999 loops=1)
    -> Index lookup on oi using ix_order_item_order_id (order_id=o.order_id)  (cost=0.668 rows=1) (actual time=0.00479..0.00515 rows=1.67 loops=8000)
```



오탈자 및 오류 내용을 댓글 또는 메일로 알려주시면, 검토 후 조치하겠습니다.

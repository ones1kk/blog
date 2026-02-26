---
title: "# MySQL MATERIALIZED 전략 이해하기"
slug: "mysql-materialized--"
date: "2026-02-26"
tags: ["devlog"]
status: "draft" # draft | published
summary: ""
cover: "./assets/cover.png"
---

# MySQL MATERIALIZED 전략 이해하기


# 들어가기 전 

열심히 배치 애플리케이션을 만들고 있던 중 개발 환경에서 테스트 중 실수로 약 10만건의 중복 프로퍼티가 적재가 되었다.
인덱스는 충분히 설계되어 있었고, 최소한의 조인을 위해 삭제 대상은 별도의 임시 테이블에 적재까지 해놓은 상태였다. 

<br> 

```sql
delete a
from tb_provider_property_image a
join tmp_delete_provider_property_ids t
  on t.provider_property_id = a.provider_property_id;
```

<br> 

이 쿼리가 40분이 지나도 끝나지 않았다.
실행 계획을 다시 확인하고, 쿼리를 재구성한 뒤 다시 실행했다. 실제 쿼리를 동작하는 테이블의 구조는 동일했지만, 실행 계획이 달라졌다. 그리고 1초 만에 끝났다.
실행 계획에 찍힌 키워드가 하나 있었다.

`MATERIALIZED`

MATERIALIZED 설명하기 전에 이 사고 때문에 delete가 어떻게 동작하는지 한 번 제대로 뜯어보게 됐다.

# MySQL(InnoDB)에서 delete는 실제로 어떻게 동작하는가

일반적으로 delete는 “데이터를 지우는 쓰기 작업”으로 이해된다. 그러나 InnoDB에서의 delete는 단순한 물리 삭제가 아니다.
이 연산은 트랜잭션 일관성, MVCC, crash recovery라는 세 가지 전제를 동시에 만족해야 하는 구조 위에서 수행된다.

따라서 delete는 다음과 같은 다층적인 단계로 구성된다.


우선 하나를 명확히 해야 한다. InnoDB는 row를 즉시 파일에서 제거하지 않는다. 삭제는 곧바로 공간을 비우는 행위가 아니라, 삭제된 버전을 하나 더 생성하는 과정에 가깝다.

## 1. 삭제 대상 탐색

아래 쿼리를 보자.

<br> 

```sql
delete a
from tb_provider_property_image a
join tmp_delete_provider_property_ids t
  on t.provider_property_id = a.provider_property_id;
``` 

<br> 

이 문장은 SQL 레벨에서는 단순해 보이지만, 엔진 레벨에서는 다음 질문으로 해석된다.

`어떤 row를 삭제해야 하는가?`

즉, delete는 row identification 단계가 선행된다.
이 단계는 완전히 읽기 작업이다.

조인이 어떻게 수행되는지, 어떤 테이블이 드라이빙 테이블로 선택되는지, 옵티마이저가 세미조인 변환을 적용했는지, 물질화를 선택했는지에 따라 실제 읽는 row 수가 결정된다.


삭제 건수가 10만 건이라 하더라도, 그 10만 건을 찾기 위해 3천만 건을 읽는다면 실질적으로 delete는 대량 읽기 작업이 된다.

Nested Loop Join 구조에서는 내부 루프의 반복 횟수가 곧 성능이다. 드라이빙 테이블 선택이 잘못되면, 내부 인덱스 탐색이 수백만 번 반복될 수 있다. 이 경우 시간의 대부분은 삭제가 아니라 탐색에 소모된다.

이 지점이 많은 사람들이 오해하는 부분이다. delete는 쓰기이기 때문에 느리다고 생각하지만, 실제로는 읽기 비용이 병목인 경우가 훨씬 많다.


## 2. delete-mark와 MVCC

삭제 대상이 확정되면 InnoDB는 즉시 row를 제거하지 않는다.
그 대신 다음 작업을 수행한다.

<br> 

1. 해당 row에 delete-mark를 설정한다.
2. undo 로그에 이전 버전을 기록한다.
3. redo 로그에 페이지 변경 사항을 기록한다.

<br> 

undo 로그는 단순히 롤백을 위한 장치가 아니다.
InnoDB는 MVCC 기반 엔진이기 때문에, 다른 트랜잭션이 동일한 row의 이전 버전을 읽고 있을 가능성을 항상 고려한다. 따라서 delete는 “데이터를 제거하는 작업”이 아니라, “삭제된 버전을 추가하는 작업”에 가깝다.

이 과정은 row 단위로 수행되며, 각 row마다 undo 레코드가 생성된다. 트랜잭션이 길어질수록 undo 히스토리는 누적된다. 만약 동시에 긴 트랜잭션이 존재한다면 purge는 이전 버전을 즉시 정리하지 못한다.

따라서 delete의 비용에는 단순한 쓰기 IO뿐 아니라, 버전 관리 비용이 포함된다.

## 3. 인덱스 엔트리의 수정

InnoDB에서 하나의 row는 다음 위치에 존재한다.

<br> 

- 클러스터드 인덱스(B+Tree)
- 모든 보조 인덱스의 B+Tree

<br>

row 하나를 삭제하면, 해당 row에 연결된 모든 인덱스 엔트리가 수정된다. 여기서 중요한 점은 delete가 인덱스를 재구성(rebuild)하는 것이 아니라, 해당 엔트리를 제거 대상으로 표시하고 B+Tree 구조를 국소적으로 수정한다는 것이다.

그러나 인덱스 개수가 많다면 row 하나당 여러 개의 B+Tree 페이지가 수정된다. 이 비용은 삭제 건수에 선형적으로 증가한다.

그럼에도 불구하고, 이 비용은 일반적으로 “2400배 차이”를 만들어내지는 않는다. 동일한 row를 삭제한다면 인덱스 수정 비용은 거의 동일하게 발생한다. 따라서 40분과 1초의 차이를 설명하기에는 충분하지 않다.

## 4. Purge와 물리적 정리

delete-mark된 row는 즉시 물리적으로 제거되지 않는다.
실제 공간 회수는 purge thread에 의해 백그라운드에서 처리된다.

만약 긴 트랜잭션이 존재하면 undo 히스토리가 누적되고 purge가 지연될 수 있다. 이 경우 delete는 단순히 느려지는 것이 아니라, InnoDB 전반의 성능에 영향을 미친다.

하지만 여기서도 동일한 조건이라면 수행 시간 차이가 극단적으로 벌어질 이유는 없다.


# 문제의 본질: 옵티마이저 전략

동일한 테이블, 동일한 데이터, 동일한 삭제 대상.
그런데 실행 계획이 바뀌자 수행 시간이 2400배 차이 났다.
이 차이를 만든 것은 InnoDB가 아니라 옵티마이저였다.

결국 차이를 만든 것은 삭제 단계가 아니라 탐색 단계였다.

DB는 40분 동안 “삭제”를 하고 있었던 것이 아니라, 삭제할 row를 찾기 위해 조인을 반복하고 있었던 것이다.


MySQL이 서브쿼리나 join을 처리할 때 선택하는 전략은 크게 다음 세 계열로 나뉜다.

1. dependent subquery (상관 서브쿼리)
2. semi-join 전략
3. materialized 전략


왜 delete 성능이 아니라 join 전략이 문제였는지를 분석해보자.


# 세미조인


# MATERIALIZED

# Optimizer_switch 실험

# Internal Temporary Table

# DELETE 이후: Undo와 Purge Lag

# 결론


<br> 

오탈자 및 오류 내용을 댓글 또는 메일로 알려주시면, 검토 후 조치하겠습니다.

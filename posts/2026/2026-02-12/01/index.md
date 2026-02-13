---
title: "혼합 워크로드 환경에서의 배치 처리 전략"
slug: "----"
date: "2026-02-12"
tags: ["devlog"]
status: "draft" # draft | published
summary: ""
cover: "./assets/cover.png"
---

# 혼합 워크로드 환경에서의 배치 처리 전략


# 들어가기 전 

배치 애플리케이션을 설계할 때 흔히 저지르는 첫 번째 오류는, 모든 작업을 하나의 성격으로 간주하는 것이다. 실제 운영 환경에서의 배치는 대개 순수한 I/O 바운드도 아니고 순수한 CPU 바운드도 아니다. 두 특성이 단계적으로, 혹은 동시에 교차한다. 문제는 이 혼합 상태를 단일 실행 모델로 처리하려 할 때 발생한다.

예를 들어 Reader는 DB에서 이미지 메타데이터를 조회하고, Processor는 외부 HTTP API를 호출하여 이미지를 분석한 뒤, 추가적으로 로컬에서 feature 계산을 수행하며, Writer는 결과를 upsert한다. 이 구조는 전형적인 혼합 워크로드다. HTTP 호출은 I/O Burst이고, feature 계산은 CPU Burst다. Writer는 다시 JDBC batch라는 I/O를 동반한다.

이 구조에서 가장 먼저 해야 할 일은 “성능 개선 기법”을 적용하는 것이 아니라, 실제 병목을 규명하는 것이다. 이 단계 없이 Virtual Thread를 도입하거나 Coroutine으로 전환하는 것은 단지 구조를 복잡하게 만들 뿐이다.

# I/O Bound와 CPU Bound의 물리적 차이

CPU Bound 작업은 스레드가 대부분 RUNNABLE 상태에 머문다. CPU를 지속적으로 점유하며 계산을 수행한다. 이 경우 병렬도는 코어 수에 의해 상한이 정해진다. 코어가 8개인 시스템에서 100개의 플랫폼 스레드를 생성하면, 실제로는 8개만 실행되고 나머지는 스케줄링 대기 상태에 머무르며 context switching 비용만 증가시킨다.

반면 I/O Bound 작업은 스레드가 대부분 BLOCKED 또는 WAITING 상태에 머문다. 외부 자원 응답을 기다리는 동안 CPU는 유휴 상태가 된다. 이 경우 전통적인 플랫폼 스레드 모델에서는 블로킹 하나당 스레드 하나가 점유된다. 동시성을 늘리려면 스레드 수를 늘려야 하고, 이는 메모리 사용량과 context switching 비용을 증가시킨다.

이 두 현상은 JVM 레벨에서 thread dump를 통해 관찰 가능하다. CPU Bound 상황에서는 RUNNABLE 스레드 비율이 높게 나타나고, I/O Bound 상황에서는 WAITING 상태 스레드가 대부분을 차지한다.

# CPU Burst

의도적으로 CPU Heavy 작업으로 구성해보자.

<br> 

```kotlin
@ParameterizedTest(name = "poolSize={0}")
@ValueSource(ints = [4, 8, 16])
fun cpu_bound_thread_pool_scaling(poolSize: Int) {
    val totalItems = 20_000
    val iterations = 200_000
    val checksum = AtomicLong(0)
    val executor = Executors.newFixedThreadPool(poolSize)

    val elapsedMs = measureTimeMillis {
        repeat(poolSize) { worker ->
            executor.submit {
                var local = 0L
                for (item in worker until totalItems step poolSize) {
                    repeat(iterations) { i -> local += (i + item) }
                }
                checksum.addAndGet(local)
            }
        }
        executor.shutdown()
        executor.awaitTermination(1, TimeUnit.HOURS)
    }

    println("poolSize=$poolSize, elapsedMs=$elapsedMs, checksum=${checksum.get()}")
}
```

<br> 

이 코드는 외부 I/O 없이 순수한 정수 연산만 반복 수행한다. 각 워커는 동일한 연산량을 분배받아 수행하며, 최종 checksum으로 계산 일관성을 검증한다. 즉, 네트워크 지연이나 메모리 블로킹 같은 변수는 배제한 상태에서 “CPU만” 소모하도록 설계된 실험이다.

실험 결과는 다음과 같다.

<br> 

```text
poolSize=4,   elapsedMs=686
poolSize=8,   elapsedMs=401
poolSize=16,  elapsedMs=391
poolSize=32,  elapsedMs=435
poolSize=64,  elapsedMs=398
poolSize=128, elapsedMs=390
poolSize=256, elapsedMs=449
```

<br>

4에서 8로 증가할 때 처리 시간은 686ms에서 401ms로 거의 절반 가까이 감소한다. 이는 물리적 코어 수에 도달하기 전까지 병렬도가 실제 계산 병렬성을 증가시키기 때문이다. CPU 코어를 충분히 활용하지 못하던 상태에서 스레드 수를 늘렸기 때문에 당연한 결과다.

<br> 

8에서 16으로 늘렸을 때 401ms에서 391ms로 소폭 감소한다. 그러나 이 구간부터는 성능 향상이 거의 정체된다. 이는 이미 CPU 코어가 대부분 사용 중이며, 추가 스레드는 실질적인 계산 병렬성을 증가시키지 못한다는 신호다.

이 시점에서부터는 “코어 수”가 상한선이 된다.

<br> 

32에서는 오히려 435ms로 증가한다. 64에서는 다시 398ms로 감소하고, 128에서는 390ms로 약간 줄어들지만, 256에서는 449ms까지 증가한다.

이 구간의 변동은 계산 능력 증가 때문이 아니라 스케줄링 비용과 캐시 간섭, context switching 비용의 영향이다. 스레드 수가 코어 수를 초과하면 JVM은 OS 스케줄러와 협력하여 스레드를 교체 실행한다. 이 과정에서 L1/L2 캐시 locality가 깨지고, 실행 컨텍스트 전환 비용이 증가한다.

즉, 추가 스레드는 계산 자원을 늘리지 않는다. 단지 경쟁을 유발할 뿐이다.

<br> 

이 실험에서 중요한 관찰은 다음과 같다.

1. 성능 향상은 코어 수 근처에서 포화된다.
2. 그 이후의 스레드 증가는 실질적인 이득을 제공하지 않는다.
3. 오히려 일부 구간에서는 처리 시간이 증가한다.
4. CPU Bound 환경에서는 thread pool을 무한히 늘리는 전략이 의미 없다.

이 결과는 “CPU Bound 작업은 코어 수에 의해 제한된다”는 교과서적 문장을 실제 수치로 검증한 것이다. 여기에는 Virtual Thread도, Coroutine도 개입하지 않았다. 순수한 fixed thread pool 환경에서조차 이미 물리적 한계가 명확히 드러난다.


# I/O Burst

앞선 CPU 실험은 물리적 코어 수가 성능 상한선을 결정한다는 사실을 수치로 확인한 과정이었다. 이제 정반대 상황, 즉 계산은 거의 없고 대부분의 시간이 외부 자원 대기 상태에 소비되는 순수 I/O Bound 환경을 구성한다.

이 실험의 목적은 단순하다. “스레드를 늘리면 I/O Bound 작업의 처리량은 어떻게 변하는가?”를 관찰하는 것이다. 그리고 그 변화가 어디에서 멈추는지를 확인하는 것이다.

실험 코드는 다음과 같다.

<br> 

```kotlin
@Test
fun io_bound_fixed_pool_only() {
    val totalRequests = 500
    val delayMs = 200L

    fun run(label: String, poolSize: Int) {
        val executor = Executors.newFixedThreadPool(poolSize)
        val latch = CountDownLatch(totalRequests)

        val elapsedMs = measureTimeMillis {
            repeat(totalRequests) {
                executor.submit {
                    Thread.sleep(delayMs) // mock HTTP I/O
                    latch.countDown()
                }
            }
            latch.await()
        }

        executor.shutdown()
        executor.awaitTermination(1, TimeUnit.MINUTES)
        println("[IO] $label elapsedMs=$elapsedMs")
    }

    run(label = "fixed-10", poolSize = 10)
    run(label = "fixed-50", poolSize = 50)
}
```

<br> 


여기서 Thread.sleep(200)은 실제 HTTP 호출을 모사한다. 이 구간 동안 스레드는 계산을 수행하지 않고 BLOCKED 상태로 머문다. 즉, CPU는 거의 사용되지 않는다. 중요한 점은 이 테스트가 “완전한 I/O 대기” 상황을 모델링하고 있다는 것이다.

<br> 


이 실험은 수학적으로 예상 가능하다.

총 요청 수는 500건이며, 각 요청은 200ms 대기한다.

동시에 실행 가능한 작업 수는 thread pool size로 제한된다.

따라서 총 처리 시간은 다음과 같이 근사할 수 있다.

총 시간 ≈ ceil(총 요청 수 / poolSize) × delayMs

예를 들어:

poolSize = 10
→ 500 / 10 = 50 batch
→ 50 × 200ms = 10,000ms ≈ 10초

poolSize = 50
→ 500 / 50 = 10 batch
→ 10 × 200ms = 2,000ms ≈ 2초

이 계산은 스케줄링 오버헤드를 무시한 이론적 최소값이다.
그리고 아래는 실제 해당 테스트코드를 실행했을 때 콘솔에 찍히는 결괏값이다. 

<br> 

```text
[IO] fixed-10 elapsedMs=10188
[IO] fixed-50 elapsedMs=2046
```

<br> 



수학적 계산과 일치한다는 것을 확인할 수 있다. 이것이 의미하는 바는 명확하다. I/O Bound 환경에서는 CPU 코어 수와 무관하게 “동시 대기 수”가 처리량을 결정한다. 스레드를 늘릴수록 처리 시간은 선형적으로 감소한다. CPU Bound 실험과는 완전히 다른 특성을 보인다.

<br> 


실행 모델 관점에서의 해석

fixed thread pool 모델에서 I/O 대기 상황은 다음과 같은 자원 구조를 가진다.

각 요청은 플랫폼 스레드 하나를 점유한다.

스레드는 sleep 동안 OS 레벨에서 WAITING 상태로 전환된다.

CPU는 해당 스레드를 실행하지 않지만, 스레드는 메모리를 점유한다.

동시 대기 수는 thread pool size로 제한된다.

즉, 이 모델은 “대기 슬롯”을 플랫폼 스레드로 구현한 것이다.

이 방식의 한계는 명확하다.

- 스레드 수를 늘릴수록 메모리 사용량 증가
- 스레드 스택 메모리 고정 비용 발생
- context switching 비용 증가 가능성
- 일정 수준 이상에서 GC 압박


실제로 poolSize를 200, 500, 1000으로 확장하면 처리 시간은 더 줄어들겠지만, 시스템은 점점 비효율적으로 변한다. OS 스케줄러와 JVM이 관리해야 할 스레드 수가 기하급수적으로 증가하기 때문이다.

병목은 어디에 존재하는가?

이 실험에서 CPU 사용률을 관찰하면 거의 낮은 수준에 머문다. 즉, CPU는 병목이 아니다.

그렇다면 병목은 어디인가?

병목은 “동시 대기 수 제한”이다. 다시 말해, 플랫폼 스레드 수가 병목이다.

이 지점에서 Virtual Thread가 등장한다.

## Virtual Thread 

Virtual Thread는 블로킹 호출이 발생하면 해당 virtual thread를 parking시키고, 플랫폼 스레드를 반환한다. 즉, “대기 슬롯”을 플랫폼 스레드가 아닌 lightweight continuation으로 표현한다.

동일한 실험을 다음과 같이 변경할 수 있다.

<br> 

```kotlin
@Test
fun io_bound_virtual_thread() {
    val totalRequests = 500
    val delayMs = 200L
    val executor = Executors.newVirtualThreadPerTaskExecutor()
    val latch = CountDownLatch(totalRequests)

    val elapsedMs = measureTimeMillis {
        repeat(totalRequests) {
            executor.submit {
                Thread.sleep(delayMs)
                latch.countDown()
            }
        }
        latch.await()
    }

    executor.shutdown()
    executor.awaitTermination(1, TimeUnit.MINUTES)
    println("[IO] virtual elapsedMs=$elapsedMs")
}
```

<br> 

이 경우, 500개의 요청은 사실상 동시에 시작된다. 이론적 처리 시간은 거의 delayMs에 근접한다.

즉, 총 시간 ≈ 200ms + 스케줄링 오버헤드 플랫폼 스레드 수는 극히 적은 상태를 유지한다. 대기 중인 작업은 continuation 상태로 저장될 뿐이다.

<br> 

```text
[IO] virtual elapsedMs=216
```

<br> 

실제 콘솔창 결과도 동일하다. 

이 실험이 보여주는 사실은 다음과 같다.

1. I/O Bound 환경에서는 동시 대기 수가 성능을 결정한다.
2. fixed thread pool은 대기 슬롯을 플랫폼 스레드로 구현한다.
3. Virtual Thread는 대기 슬롯을 경량 continuation으로 구현한다.
4. CPU 사용률은 거의 영향을 받지 않는다.
5. 병목은 “계산 능력”이 아니라 “대기 표현 방식”이다.

<br> 

여기서 매우 중요한 통찰이 하나 발생한다.

CPU 실험에서는 스레드를 늘려도 성능이 증가하지 않았다.
I/O 실험에서는 스레드를 늘릴수록 성능이 선형적으로 증가했다.

이 두 실험을 결합하면 다음 질문이 자연스럽게 도출된다.

“만약 하나의 작업이 I/O와 CPU를 동시에 포함한다면, 동시성을 어디까지 올릴 수 있는가?”

답은 단순하지 않다.

I/O가 지배적일 때는 Virtual Thread가 효과적이지만 CPU 구간이 충분히 커지는 순간, 병목은 다시 코어 수로 이동한다.

이것이 혼합 워크로드 환경이 단순한 thread pool 확장 문제로 해결되지 않는 이유다.


# I/O + CPU 혼 워크로드 

앞선 두 실험은 의도적으로 극단을 만들었다. 첫 번째는 계산만 존재하는 환경이었고, 두 번째는 대기만 존재하는 환경이었다. 그러나 실제 배치 시스템은 이 두 극단의 어느 한쪽에 속하지 않는다. 대부분의 실무 배치는 I/O 구간과 CPU 구간이 순차적으로 결합되어 있으며, 두 구간의 비율이 전체 처리량을 결정한다.

이번 실험에서는 각 작업이 평균 200ms의 I/O 대기와 약 20ms의 CPU 연산을 포함하도록 구성한다. 이 비율은 실제 외부 HTTP 호출 후 JSON 파싱이나 간단한 feature 계산을 수행하는 상황을 모사한다. 즉, 대기 시간이 계산 시간보다 10배 길지만, 계산 구간이 완전히 무시할 수준은 아닌 구조다.

테스트 코드는 다음과 같이 구성할 수 있다.

<br> 

```kotlin
@Test
fun mixed_workload_fixed_pool() {
    val totalRequests = 500
    val ioDelayMs = 200L
    val cpuIterations = 2_000_000
    val poolSize = 50

    val executor = Executors.newFixedThreadPool(poolSize)
    val latch = CountDownLatch(totalRequests)

    val elapsedMs = measureTimeMillis {
        repeat(totalRequests) {
            executor.submit {
                // I/O burst
                Thread.sleep(ioDelayMs)

                // CPU burst
                var acc = 0L
                repeat(cpuIterations) { i ->
                    acc += i
                }

                latch.countDown()
            }
        }
        latch.await()
    }

    executor.shutdown()
    executor.awaitTermination(1, TimeUnit.MINUTES)
    println("[MIXED] elapsedMs=$elapsedMs")
}

```

<br> 

이 실험의 핵심은 단순한 실행 시간이 아니다. 관찰해야 할 것은 동시성 증가에 따라 병목이 어디로 이동하는지다.

이론적 최소 처리 시간 계산

순수 I/O 환경에서 poolSize=50이라면, 이론적 최소 시간은 다음과 같이 계산된다.

총 요청 수 500건
동시 처리 50건
200ms × (500 / 50) = 200ms × 10 = 2000ms

즉, 약 2초 수준이 기대값이다.

그러나 이제 각 작업에는 CPU 20ms가 추가된다. 단순 계산하면 200ms + 20ms = 220ms이므로 총 처리 시간은 약 2200ms가 될 것이라 예측할 수 있다. 하지만 실제 결과는 이 단순 합산보다 더 길어진다. 이유는 CPU 구간이 겹치기 때문이다.

50개의 작업이 동시에 I/O를 마치고 CPU 계산을 시작하면, 그 순간 50개의 RUNNABLE 스레드가 동시에 CPU를 요구한다. 물리적 코어가 8개라면, 이 50개의 스레드는 순차적으로 스케줄링되며 계산을 수행해야 한다. 그 결과, CPU 구간이 병목으로 전환된다.

## Virtual Thread 적용 혼합 워크로드 

동일 실험을 Virtual Thread로 변경한다.

<br> 

```kotlin 
@Test
fun mixed_workload_virtual_thread() {
    val totalRequests = 500
    val ioDelayMs = 200L
    val cpuIterations = 2_000_000

    val executor = Executors.newVirtualThreadPerTaskExecutor()
    val latch = CountDownLatch(totalRequests)

    val elapsedMs = measureTimeMillis {
        repeat(totalRequests) {
            executor.submit {
                Thread.sleep(ioDelayMs)

                var acc = 0L
                repeat(cpuIterations) { i ->
                    acc += i
                }

                latch.countDown()
            }
        }
        latch.await()
    }

    executor.shutdown()
    executor.awaitTermination(1, TimeUnit.MINUTES)
    println("[MIXED-VT] elapsedMs=$elapsedMs")
}
```

<br> 

이 경우 I/O 구간은 거의 완벽하게 병렬화된다. 그러나 CPU 구간은 여전히 물리적 코어 수에 의해 제한된다. Virtual Thread는 블로킹 대기를 효율적으로 표현하지만, CPU 계산 구간에서는 플랫폼 스레드 위에서 실행된다. 따라서 CPU 구간이 지배적으로 변하는 순간, 처리량은 다시 코어 수에 의해 제한된다.

즉, Virtual Thread는 병목을 제거하지 않는다. 병목의 위치를 이동시킬 뿐이다.


# I/O 이후 CPU 연산이 직렬로 결합된 구조적 혼합 워크로드

앞선 실험에서 우리는 I/O와 CPU가 동시에 존재할 때 병목이 이동한다는 사실을 확인했다. 그러나 실제 운영 환경에서 더 빈번하게 등장하는 패턴은 단순 혼합이 아니라 의존적 결합 구조다.

작업은 다음과 같은 단계로 진행된다.

1. 외부 리소스에 HTTP 요청을 보낸다.
2. 응답 상태를 검증한다.
3. 응답 바이트를 읽는다.
4. 해당 바이트를 기반으로 CPU 집약적 연산을 수행한다.
5. 계산 결과를 저장한다.

여기서 중요한 점은 CPU 연산이 I/O 이후에 반드시 수행되어야 한다는 점이다. 즉, 두 연산이 병렬로 분리될 수 없다. 이것이 문제의 본질이다.
이 구조는 겉보기에는 I/O가 지배적이다. 네트워크 왕복 시간이 200ms, CPU 계산이 20ms라면, 대부분의 개발자는 I/O Bound라고 판단한다. 그래서 동시성을 대폭 늘리고 Virtual Thread를 도입한다.

그러나 일정 수준 이상 동시성을 올리는 순간 다음 현상이 발생한다.

I/O가 동시에 완료되는 순간, 대량의 CPU 작업이 한꺼번에 RUNNABLE 상태로 전환된다.

이 현상을 "burst convergence"라고 부를 수 있다.
대기 상태였던 수백 개의 작업이 동시에 계산 구간으로 진입하면서 CPU에 대한 경쟁이 폭발적으로 증가한다.

## 실행 모델 분리 

이 구조에서 유일하게 안정적인 해결책은 실행 모델을 분리하는 것이다.

I/O는 높은 동시성을 허용한다.
CPU는 코어 수에 맞게 제한한다.

이때 핵심은 “직렬 의존 구조를 물리적으로 분리”하는 것이다.

예를 들어 다음과 같은 구조가 가능하다.

1. I/O 단계는 Virtual Thread로 고동시성 처리
2. I/O 완료 후 CPU 작업은 별도 bounded executor로 전달
3. CPU executor는 core 수에 맞게 제한
4. backpressure 발생 시 I/O 단계에서 조절

이 구조의 핵심은 CPU burst를 완충하는 버퍼 계층을 두는 것이다.

<br>

```kotlin
val ioExecutor = Executors.newVirtualThreadPerTaskExecutor()

val cpuExecutor = Executors.newFixedThreadPool(
    Runtime.getRuntime().availableProcessors()
)

fun processTask(task: Task) {
    CompletableFuture
    .supplyAsync({ performIo(task) }, ioExecutor)
    .thenApplyAsync({ response ->
        performCpuComputation(response)
    }, cpuExecutor)
    .join()
}
```

<br> 

위 코드에서 핵심은 I/O와 CPU를 서로 다른 executor에 명시적으로 분리했다는 점이다. I/O 단계는 virtual thread 기반으로 사실상 높은 동시성을 허용하고, CPU 단계는 물리적 코어 수에 맞게 제한한다. 겉보기에는 이것으로 문제가 해결된 것처럼 보인다. 실제로 순수 I/O 환경에서는 처리량이 극적으로 개선될 것이고, CPU 단계 역시 무제한 경쟁 상태에 빠지지는 않는다.

그러나 여기에서 멈추면 안 된다. 이 구조는 “실행 자원 분리”라는 1차적인 문제만 해결했을 뿐, 혼합 워크로드의 본질적인 위험을 완전히 제거한 것은 아니다.

첫 번째로 고려해야 할 것은 join()의 위치다. 이 코드는 결국 호출 스레드가 최종 결과를 기다린다. 만약 이 호출자가 플랫폼 스레드라면, 우리는 I/O 단계에서 virtual thread를 사용했음에도 불구하고 다시 플랫폼 스레드 블로킹 모델로 회귀하게 된다. 반대로 호출자 자체가 virtual thread라면, 이 대기는 플랫폼 자원을 점유하지 않는다. 즉, “누가 기다리느냐”는 이 구조에서 결정적인 요소다. 실행 모델을 분리했지만, 호출 스레드의 성격을 고려하지 않으면 전체 시스템 관점에서는 여전히 병목이 남는다.

두 번째로 중요한 것은 backpressure다. 위 구조는 CPU executor를 코어 수에 맞게 제한했지만, CPU 단계로 전달되는 작업의 유입 자체를 제어하지는 않는다. 만약 I/O가 매우 빠르게 완료되고, 그 결과가 CPU executor의 큐에 대량으로 적재된다면, 우리는 CPU 스레드 수는 제한했지만 큐 길이는 제한하지 않은 상태가 된다. 이 경우 처리량은 일정하게 유지되더라도 대기 시간이 폭증하며, 메모리 사용량이 증가하고, 결국 GC 압력이 상승한다. 혼합 워크로드에서 가장 흔한 장애 모드는 CPU 스레드 부족이 아니라 CPU 큐 적체다.

따라서 “실행 모델 분리”는 단순히 executor를 나누는 것이 아니라, CPU 단계로 들어가는 관문에서 유입을 조절하는 전략까지 포함해야 한다. 다시 말해, CPU 단계는 코어 수에 맞게 병렬성을 제한할 뿐 아니라, 동시에 처리 가능한 작업 수 자체도 상한을 둬야 한다. 그렇지 않으면 I/O에서 밀어 넣는 속도와 CPU가 소비하는 속도 사이의 불균형이 점점 커지며, 시스템은 결국 비정상 상태로 진입한다.

이 시점에서 우리는 혼합 워크로드의 본질을 명확히 이해하게 된다. 문제는 I/O도, CPU도 아니다. 문제는 “두 자원의 속도 차이”다. I/O는 지연이 크지만 병렬화가 자유롭고, CPU는 지연이 작지만 병렬화에 물리적 상한이 존재한다. 이 두 특성이 직렬 의존 구조로 묶이는 순간, 병목은 동적으로 이동하며, 어느 한쪽을 최적화하는 순간 다른 쪽이 드러난다.

그렇다면 이 글에서 제시한 구조는 의미가 없는가. 그렇지 않다. 이 구조는 최소한 다음 두 가지를 보장한다.

첫째, I/O 대기 때문에 플랫폼 스레드가 낭비되지 않는다. 이는 고동시성 HTTP 호출 환경에서 매우 중요한 개선이다.
둘째, CPU 경쟁이 물리적 코어 수를 초과하지 않도록 제한한다. 이는 tail latency 폭증을 억제하는 데 핵심적이다.

다만, 이 구조는 반드시 다음 조건을 전제로 해야 한다.

1. 호출자가 virtual thread이거나, 적어도 플랫폼 스레드 점유를 최소화하도록 설계되어 있을 것.
2. CPU executor의 큐 길이를 모니터링하고, 필요하다면 I/O 동시성을 동적으로 낮출 수 있을 것.
3. Spring Batch 환경이라면 processor 내부에서 최종 결과를 동기적으로 반환하여 chunk 트랜잭션 의미를 보존할 것, 혹은 I/O 단계와 CPU 단계를 서로 다른 step으로 분리할 것.

이 세 가지가 충족되지 않으면, 구조는 겉보기에는 세련되어 보이지만 운영 환경에서는 예측 불가능한 병목을 만들어낸다.

이 글에서 수행한 실험들을 다시 정리해보자. CPU만 존재하는 경우, 동시성은 코어 수에 의해 제한되었다. I/O만 존재하는 경우, 동시성은 대기 슬롯 수에 의해 제한되었다. 그리고 I/O 이후 CPU가 직렬로 결합된 구조에서는, 병목이 동적으로 이동하며 burst convergence 현상이 발생했다. 이는 단순한 이론이 아니라, thread state와 CPU 사용률, 처리 시간 변화를 통해 관찰 가능한 물리적 현상이다.

결국 혼합 워크로드의 정답은 “더 많은 스레드”도 아니고, “더 새로운 실행 모델”도 아니다. 정답은 자원 특성에 대한 이해와, 그 특성에 맞춘 실행 모델 분리, 그리고 유입 제어다. Virtual Thread는 강력한 도구지만, 그것이 CPU를 늘려주지는 않는다. Coroutine은 유연한 비동기 모델을 제공하지만, 물리적 코어 수를 초월하지는 못한다. 기술은 병목을 제거하는 것이 아니라, 병목의 위치를 이동시킬 뿐이다.

따라서 혼합 워크로드 환경에서의 성능 개선은 다음과 같은 사고 순서를 따른다. 먼저 병목을 측정하고, 그 병목이 I/O인지 CPU인지 구분한다. 그 다음 실행 모델을 분리하고, CPU 병렬성을 물리적 한계에 맞게 제한한다. 마지막으로 유입 제어와 큐 길이를 관리하여 tail latency와 메모리 사용량을 안정화한다.

이 과정을 거치지 않은 동시성 증가는 단기적인 처리량 개선처럼 보일 수 있으나, 결국 다른 자원에서 더 큰 비용을 치르게 만든다. 혼합 워크로드는 복잡해 보이지만, 본질은 단순하다. 자원의 속도 차이를 인정하고, 그 차이를 완충하는 구조를 설계하는 것이다.

여기까지가 I/O 이후 CPU 연산이 직렬로 결합된 구조적 혼합 워크로드에 대한 최종 결론이다.

<br> 

오탈자 및 오류 내용을 댓글 또는 메일로 알려주시면, 검토 후 조치하겠습니다.

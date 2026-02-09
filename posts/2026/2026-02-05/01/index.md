---
title: "KAPT와 KSP"
slug: "kapt-ksp"
date: "2026-02-05"
tags: ["devlog"]
status: "draft" # draft | published
summary: ""
cover: "./assets/cover.png"
---

# KAPT와 KSP

# 들어가기 전 

KAPT와 KSP를 이해하려면, 결국 자바 어노테이션 프로세서부터 다시 봐야 한다

코틀린에서 KAPT와 KSP를 논하기 전에 반드시 짚고 넘어가야 할 전제가 하나 있다.
KAPT와 KSP는 “코틀린의 기능”이 아니라, 자바 어노테이션 프로세싱이라는 오래된 JVM 생태계의 설계를 어떻게 수용하거나, 혹은 거부할 것인가에 대한 선택지다.

자바의 어노테이션 프로세서는 컴파일러 확장 포인트로서 설계되었다. 소스 코드에 선언된 어노테이션을 읽고, 그 정보를 기반으로 새로운 소스 코드를 생성하는 메커니즘이다. 대표적으로 Lombok, MapStruct, Dagger, QueryDSL 같은 라이브러리들이 이 메커니즘 위에서 동작한다.

중요한 점은 이 시스템이 자바 컴파일러(javac)의 타입 시스템과 AST를 전제로 설계되었다는 사실이다. 어노테이션 프로세서는 컴파일 타임에 javax.annotation.processing.Processor를 구현한 클래스로 로딩되고, javac가 파싱한 소스 모델을 TypeElement, ExecutableElement, VariableElement 같은 추상화된 인터페이스를 통해 접근한다.

이 구조는 매우 강력하지만 동시에 강한 제약을 가진다. 어노테이션 프로세서는 소스 코드의 “의미”가 아니라, javac가 해석한 “자바 언어 모델”만을 볼 수 있다. 이 말은 곧, 다른 언어가 JVM 위에서 돌아가더라도 결국 자바 언어로 환원되지 않으면 이 시스템을 직접 사용할 수 없다는 뜻이다.

여기서 코틀린의 문제가 시작된다.


# Java Annotation Processing

코틀린의 KAPT와 KSP이 무엇인지 알아보기 전, 먼저 자바 어노테이션 프로세싱이 무엇이며 어떤 문제를 해결하려고 등장했는지부터 봐야 한다.
이 메커니즘은 이름처럼 단순히 “어노테이션을 읽는다” 수준의 기능이 아니라, 컴파일러가 확장되는 지점이다.

소스 코드에 붙은 어노테이션을 컴파일러가 해석하고, 그 정보를 기반으로 새로운 소스 코드를 생성한 뒤 다시 컴파일 대상에 포함시킨다.

여기서 중요한 점은 두 가지다.

첫째, 이 과정은 런타임이 아니라 컴파일 타임에 일어난다.
둘째, 어노테이션 프로세서는 자바 컴파일러(javac)의 타입 시스템과 AST 위에서만 동작한다.

즉, 자바 어노테이션 프로세싱은 “라이브러리 기능”이 아니라, javac 내부 파이프라인의 일부다.


런타임 시점이 아닌 컴파일 시점에 이런 식으로 처리했던 이유는 자바 초기에는 리플렉션을 활용하였지만 규모가 커질수록 리플렉션은 느리고, 타입 안정성이 없으며, IDE나 컴파일러가 코드 구조를 추론하기 어렵다는 단점이 부각되었다.
특히 DI, 매핑 코드, 반복적인 보일러플레이트가 많은 영역에서는 런타임 리플렉션보다 컴파일 타임 코드 생성이 훨씬 유리했다.

그래서 자바는 “컴파일 중에 코드 구조를 읽고, 코드를 만들어내는 공식적인 방법”을 언어 차원에서 제공하게 된다.
그게 바로 어노테이션 프로세싱이다.

## 실행 과정 

자바 소스 코드가 파싱되고, 타입 정보가 정리된 이후, .class 파일이 생성되기 이전에 실행된다.
즉, 타입 정보는 존재하지만, 바이트코드는 아직 만들어지지 않은 시점이다.

어노테이션 프로세서는

- 클래스의 이름
- 패키지
- 필드와 메서드 시그니처
- 생성자
- 제네릭 구조

같은 “언어 구조”는 볼 수 있지만, 실제 실행 로직이나 바이트코드 수준의 정보는 볼 수 없는 점이 바로 구조를 읽고 구조를 만들어내는 도구로써 설계의 핵심이다.

김영한님꼐서 백문이 불여일타라 했다.  가장 단순한 어노테이션 프로세싱 예제를 통해 동작 방식을 살펴보자. 

<br> 

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.SOURCE)
public @interface GenerateHello {
}
```

<br> 

이 어노테이션은 클래스에만 붙고, 컴파일 타임에만 의미를 가진다. 즉 런타임에는 존재하지 않는다.
이제 이 어노테이션을 처리하는 프로세서를 만든다.

<br> 


```java
@SupportedAnnotationTypes("example.annotation.GenerateHello")
@SupportedSourceVersion(SourceVersion.RELEASE_21)
public class HelloProcessor extends AbstractProcessor {

    @Override
    public boolean process(
        Set<? extends TypeElement> annotations,
        RoundEnvironment roundEnv
    ) {
        for (Element element : roundEnv.getElementsAnnotatedWith(GenerateHello.class)) {
            if (element.getKind() != ElementKind.CLASS) continue;

            TypeElement type = (TypeElement) element;
            generateHelloClass(type);
        }
        return true;
    }

    private void generateHelloClass(TypeElement type) {
        String packageName =
            processingEnv.getElementUtils()
                .getPackageOf(type)
                .getQualifiedName()
                .toString();

        String originalName = type.getSimpleName().toString();
        String generatedName = originalName + "Hello";

        try {
            JavaFileObject file = processingEnv
                .getFiler()
                .createSourceFile(packageName + "." + generatedName);

            try (Writer writer = file.openWriter()) {
                writer.write("package " + packageName + ";\n\n");
                writer.write("public class " + generatedName + " {\n");
                writer.write("    public static void hello() {\n");
                writer.write("        System.out.println(\"Hello from generated code\");\n");
                writer.write("    }\n");
                writer.write("}\n");
            }
        } catch (Exception ignored) {
        }
    }
}
```

<br> 

이 코드는 리플렉션을 전혀 사용하지 않는다.
대신 TypeElement, ElementKind, RoundEnvironment 같은 컴파일러 모델을 사용한다.

즉, 이 프로세서는 “실행 중인 클래스”를 보는 게 아니라, 컴파일러가 인식한 소스 구조를 읽고 있다.


이렇게 createSourceFile로 생성된 `.java` 파일을 javac는 그 파일을 같은 컴파일 사이클 안에서 다시 컴파일 대상에 포함시킨다.

1. 원본 클래스에 어노테이션 선언
2. 프로세서가 새로운 클래스 생성
3. 생성된 클래스가 바로 다음 단계에서 컴파일됨
4. 생성된 클래스를 다른 클래스에서 참조 가능


리플렉션의 단점을 보완하고 컴파일러가 인식한 소스 구조를 다시 재구조화시킴으로써 정적 코드 생성 전용 메커니즘으로써 잘 동작하는 것으로 보인다. 
하지만 여기서 문제가 발생한다. 
자바 어노테이션 프로세싱은 **자바에서는** 매우 잘 작동한다.
모든 입력은 자바 소스여야하고 모든 타입 모델은 javac의 언어 모델이여만 한다.
자바 언어를 벗어나는 순간 자바 어노테이션 프로세싱은 동작이 깨져버린다.
바로 이 지점에서 코틀린이 문제를 만든다.


# Kotlin 

코틀린은 JVM 위에서 동작하지만, 자바의 언어 모델과는 근본적으로 다르다.

null-safety, data class, primary constructor, property, top-level function, suspend function, inline, reified type parameter 같은 개념은 자바의 AST에는 존재하지 않는다.
자바 AST가 아닌, 독자적인 언어 모델을 가지며 kotlinc를 사용한다.

이 지점이 중요하다.
자바 어노테이션 프로세싱은 “JVM용 범용 메커니즘”이 아니라, javac와 자바 언어 모델에 깊게 결합된 시스템이다.
따라서 코틀린은 단순히 “JVM 위에서 도니까 그대로 쓰면 되겠지”라는 선택을 할 수 없다.

코틀린 컴파일러는 소스 코드를 바로 JVM 바이트코드로 변환하지 않는다.
그 사이에는 다단계의 분석과 변환, 이른바 lowering 과정이 존재한다.

예를 들어 data class 하나를 생각해보자.
코틀린 소스에서는 단 한 줄의 선언이지만, 컴파일러 내부에서는 다음과 같은 의미가 암묵적으로 포함된다.

이 클래스는 불변 데이터 컨테이너이며,
구조적 동등성을 기반으로 equals와 hashCode가 정의되고, componentN 함수들을 통해 구조 분해가 가능하며, copy 함수를 통해 일부 필드를 변경한 새 인스턴스를 생성할 수 있어야 한다.

이 모든 의미는 kotlinc가 내부 IR 단계에서 해석하고, 여러 번의 lowering을 거쳐 필드, 메서드, synthetic 함수들로 분해된 JVM 바이트코드로 변환된다.

중요한 점은, 이 과정 전체가 자바 소스 코드로는 표현되지 않는다는 사실이다.
이것은 “자바로 작성할 수 있다 / 없다”의 문제가 아니라, 자바 언어 모델이 이러한 개념을 담도록 설계되지 않았기 때문이다.

여기서 질문은 자연스럽게 하나로 수렴한다.

자바 언어 모델을 전제로 설계된 이 어노테이션 프로세싱 시스템을 자바 언어가 아닌 코틀린에서 어떻게 사용할 것인가?

이 질문에 대한 첫 번째 대답이 KAPT다.
KAPT는 코틀린을 자바처럼 보이게 만들어, 기존 자바 어노테이션 프로세서를 그대로 사용하겠다는 선택이다. 

그리고 이 질문에 대한 두 번째 대답이 KSP다.
KSP는 자바 언어 모델을 기준으로 한 프로세싱 자체를 포기하고, 코틀린 컴파일러가 이해하는 세계를 그대로 외부에 노출하겠다는 선택이다.

# KAPT 

KAPT는 Kotlin Annotation Processing Tool의 약자다. 이름만 보면 코틀린 전용 어노테이션 프로세싱 시스템처럼 보이지만, 실제로 KAPT는 새로운 프로세싱 모델을 제공하지 않는다.

KAPT는 단순히 코틀린에서 기존 자바 어노테이션 프로세서를 계속 사용하기 위한 어댑터로 코틀린의 언어 모델을 자바 언어 모델로 최대한 축소·번역하는 역할을 맡는다.


KAPT의 전략은 코틀린 소스를 직접 처리하려 하지 않고 코틀린 소스를 자바 어노테이션 프로세서가 이해할 수 있는 형태로 위장시키기 위해 다음과 같은 파이프라인을 구성한다. 

1. 먼저 코틀린 컴파일러가 코틀린 소스를 파싱하고, 타입 분석과 시그니처 해석을 포함한 내부 IR을 생성한다.
2. 그 다음 KAPT는 이 IR을 입력으로 받아 “스텁(stub)”이라 불리는 가짜 자바 소스 코드를 생성한다.
3. 이 스텁은 실행 가능한 코드가 아니며 실제 로직은 거의 비어 있고, 어노테이션 프로세서가 필요로 하는 최소한의 구조만 포함한다. 클래스 이름, 패키지, 필드 시그니처, 메서드 시그니처, 어노테이션 정보 그 외의 의미는 대부분 제거된다. 

스텁이 생성되면, KAPT는 이 가짜 자바 소스를 javac에 넘긴다.
KAPT는 단순히 프로세서를 실행하는 것이 javac 자체를 다시 실행하는 것이다. 

즉, 전체 컴파일 흐름은 다음과 같이 분기된다.

코틀린 컴파일러가 한 번 돌고, 그 결과를 기반으로 자바 스텁이 만들어지고, 그 스텁을 대상으로 javac가 다시 실행되며, 그 안에서 자바 어노테이션 프로세서가 돌아간다.

그리고 이 프로세서가 생성한 자바 소스는 다시 코틀린 컴파일 파이프라인에 합류한다. 

즉 이 구조는 사실상 컴파일 파이프라인이 한 번 더 접혔다 펼쳐지는 구조, 즉 **이중 컴파일**이다.

## 한계 

KAPT를 이야기할 때 가장 흔히 언급되는 문제는 빌드 성능이다.
이중 컴파일, 스텁 생성, javac 실행이라는 구조 때문에 느릴 수밖에 없다는 설명은 기술적으로 맞다.
하지만 이건 표면적인 결과일 뿐, KAPT가 안고 있는 더 본질적인 한계는 따로 있다.

그 한계는 성능이 아니라 언어 표현력의 손실이다.

KAPT는 코틀린 코드를 처리하지 않는다.
정확히 말하면, 코틀린 코드를 자바 어노테이션 프로세서가 이해할 수 있는 형태로 번역한 결과만 처리한다.
이 번역 과정에서 코틀린 언어가 의도적으로 제공하는 추상화는 대부분 소거된다.

코드로 살펴보자. 

```kotlin
plugins {
    kotlin("jvm")
    kotlin("kapt")
}
```

<br> 


```kotlin 
@Target(AnnotationTarget.CLASS)
annotation class Marker

@Marker
class User(
    val id: Long,
    val name: String?,
)
```

<br> 


빌드하고 `build/tmp/kapt3/stubs/main/` 스텁 디렉토리를 열어본다. 

<br> 

```java
@Marker
public final class User {
  private final long id;
  private final java.lang.String name;

  public User(long id, java.lang.String name) {
    this.id = id;
    this.name = name;
  }

  public final long getId() {
    return this.id;
  }

  public final java.lang.String getName() {
    return this.name;
  }
}
```

<br> 

어노테이션은 그대로 복사되지만 코틀린의 언어적 의미는 이 스텁 생성 단계에서 대부분 소거되며, 자바 어노테이션 프로세서는 이 번역된 결과물만을 입력으로 받는다.

코틀린의 property는 더 이상 property가 아니다.
자바 언어 모델 위에서는 필드와 getter/setter 조합으로 환원되는 것이다. 
null-safety는 타입 시스템의 일부가 아니라, 있을 수도 있고 없을 수도 있는 힌트가 된다.
primary constructor가 가진 선언적 의미는 사라지고, 단순한 생성자 시그니처만 남는다.

이 시점에서 어노테이션 프로세서가 보고 있는 것은 “코틀린 코드”가 아니라 코틀린에서 파생된 자바 유사 구조다.

이 차이는 미묘해 보이지만, 실제로는 결정적이다.
어노테이션 프로세서는 더 이상 “언어의 의미”를 다루지 못하고, 오직 번역된 결과물의 형태만을 다룬다.


<br> 

오탈자 및 오류 내용을 댓글 또는 메일로 알려주시면, 검토 후 조치하겠습니다.

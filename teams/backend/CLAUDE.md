# Backend 팀

## 도메인
- ATS(Applicant Tracking System) 채용 관리 시스템
- 주요 엔티티: Applicant, JobPosting, Interview, Evaluation, Offer

## 필수 규칙
- SQL 파라미터 바인딩 필수 (문자열 연결 금지)
- SELECT * 금지
- DDL 변경은 Flyway 마이그레이션 필수
- System.out 금지 (@Slf4j 사용)

## 코드 작성 시
코드 컨벤션 상세는 /convention-backend 스킬을 참고하라

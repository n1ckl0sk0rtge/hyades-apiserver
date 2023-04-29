DROP FUNCTION IF EXISTS "CVSSV2_TO_SEVERITY"(numeric);
DROP FUNCTION IF EXISTS "CVSSV3_TO_SEVERITY"(numeric);

-- CREATE MATERIALIZED VIEW "PORTFOLIO_METRICS_VIEW"
-- AS
-- SELECT COUNT(*)::INT                                      AS "PROJECTS",
--        2                                                  AS "VULNERABLEPROJECTS", -- TODO
--        SUM("COMPONENTS")::INT                             AS "COMPONENTS",
--        SUM("VULNERABLECOMPONENTS")::INT                   AS "VULNERABLECOMPONENTS",
--        SUM("VULNERABILITIES")::INT                        AS "VULNERABILITIES",
--        SUM("CRITICAL")::INT                               AS "CRITICAL",
--        SUM("HIGH")::INT                                   AS "HIGH",
--        SUM("MEDIUM")::INT                                 AS "MEDIUM",
--        SUM("LOW")::INT                                    AS "LOW",
--        SUM("UNASSIGNED_SEVERITY")::INT                    AS "UNASSIGNED_SEVERITY",
--        SUM("FINDINGS_TOTAL")::INT                         AS "FINDINGS_TOTAL",
--        SUM("FINDINGS_AUDITED")::INT                       AS "FINDINGS_AUDITED",
--        SUM("FINDINGS_UNAUDITED")::INT                     AS "FINDINGS_UNAUDITED",
--        SUM("SUPPRESSED")::INT                             AS "SUPPRESSED",
--        SUM("POLICYVIOLATIONS_TOTAL")::INT                 AS "POLICYVIOLATIONS_TOTAL",
--        SUM("POLICYVIOLATIONS_FAIL")::INT                  AS "POLICYVIOLATIONS_FAIL",
--        SUM("POLICYVIOLATIONS_WARN")::INT                  AS "POLICYVIOLATIONS_WARN",
--        SUM("POLICYVIOLATIONS_INFO")::INT                  AS "POLICYVIOLATIONS_INFO",
--        SUM("POLICYVIOLATIONS_AUDITED")::INT               AS "POLICYVIOLATIONS_AUDITED",
--        SUM("POLICYVIOLATIONS_UNAUDITED")::INT             AS "POLICYVIOLATIONS_UNAUDITED",
--        SUM("POLICYVIOLATIONS_LICENSE_TOTAL")::INT         AS "POLICYVIOLATIONS_LICENSE_TOTAL",
--        SUM("POLICYVIOLATIONS_LICENSE_AUDITED")::INT       AS "POLICYVIOLATIONS_LICENSE_AUDITED",
--        SUM("POLICYVIOLATIONS_LICENSE_UNAUDITED")::INT     AS "POLICYVIOLATIONS_LICENSE_UNAUDITED",
--        SUM("POLICYVIOLATIONS_OPERATIONAL_TOTAL")::INT     AS "POLICYVIOLATIONS_OPERATIONAL_TOTAL",
--        SUM("POLICYVIOLATIONS_OPERATIONAL_AUDITED")::INT   AS "POLICYVIOLATIONS_OPERATIONAL_AUDITED",
--        SUM("POLICYVIOLATIONS_OPERATIONAL_UNAUDITED")::INT AS "POLICYVIOLATIONS_OPERATIONAL_UNAUDITED",
--        SUM("POLICYVIOLATIONS_SECURITY_TOTAL")::INT        AS "POLICYVIOLATIONS_SECURITY_TOTAL",
--        SUM("POLICYVIOLATIONS_SECURITY_AUDITED")::INT      AS "POLICYVIOLATIONS_SECURITY_AUDITED",
--        SUM("POLICYVIOLATIONS_SECURITY_UNAUDITED")::INT    AS "POLICYVIOLATIONS_SECURITY_UNAUDITED"
-- FROM (SELECT DISTINCT ON ("PM"."PROJECT_ID") *
--       FROM "PROJECTMETRICS" AS "PM"
--       ORDER BY "PM"."PROJECT_ID", "PM"."LAST_OCCURRENCE" DESC) AS "LATEST_PROJECT_METRICS"
-- WITH NO DATA;

CREATE OR REPLACE FUNCTION "CVSSV2_TO_SEVERITY"(
    "base_score" NUMERIC
) RETURNS VARCHAR
    LANGUAGE "plpgsql"
AS
$$
BEGIN
    RETURN CASE
               WHEN "base_score" >= 7 THEN 'HIGH'
               WHEN "base_score" >= 4 THEN 'MEDIUM'
               WHEN "base_score" > 0 THEN 'LOW'
               ELSE 'UNASSIGNED'
        END;
END;
$$;

CREATE OR REPLACE FUNCTION "CVSSV3_TO_SEVERITY"(
    "base_score" NUMERIC
) RETURNS VARCHAR
    LANGUAGE "plpgsql"
AS
$$
BEGIN
    RETURN CASE
               WHEN "base_score" >= 9 THEN 'CRITICAL'
               WHEN "base_score" >= 7 THEN 'HIGH'
               WHEN "base_score" >= 4 THEN 'MEDIUM'
               WHEN "base_score" > 0 THEN 'LOW'
               ELSE 'UNASSIGNED'
        END;
END;
$$;

CREATE OR REPLACE FUNCTION "CALC_SEVERITY"(
    "severity" VARCHAR,
    "cvssv3_base_score" NUMERIC,
    "cvssv2_base_score" NUMERIC
) RETURNS VARCHAR
    LANGUAGE "plpgsql"
AS
$$
BEGIN
    IF "cvssv3_base_score" IS NOT NULL THEN
        RETURN "CVSSV3_TO_SEVERITY"("cvssv3_base_score");
    ELSEIF "cvssv2_base_score" IS NOT NULL THEN
        RETURN "CVSSV2_TO_SEVERITY"("cvssv2_base_score");
    ELSEIF "severity" IS NOT NULL THEN
        RETURN "severity";
    ELSE
        RETURN 'UNASSIGNED';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION "CALC_RISK_SCORE"(
    "critical" INT,
    "high" INT,
    "medium" INT,
    "low" INT,
    "unassigned" INT
) RETURNS NUMERIC
    LANGUAGE "plpgsql"
AS
$$
BEGIN
    RETURN ("critical" * 10) + ("high" * 5) + ("medium" * 3) + ("low" * 1) + ("unassigned" * 5);
END;
$$;

CREATE OR REPLACE PROCEDURE "UPDATE_COMPONENT_METRICS"(
    "component_uuid" VARCHAR
)
    LANGUAGE "plpgsql"
AS
$$
DECLARE
    "v_component"                               RECORD; -- The component to update metrics for
    "v_vulnerability"                           RECORD; -- Loop variable for iterating over vulnerabilities the component is affected by
    "v_severity"                                VARCHAR; -- Loop variable for the current vulnerability's severity
    "v_policy_violation"                        RECORD; -- Loop variable for iterating over policy violations assigned to the component
    "v_vulnerabilities"                         INT := 0; -- Total number of vulnerabilities
    "v_critical"                                INT := 0; -- Number of vulnerabilities with critical severity
    "v_high"                                    INT := 0; -- Number of vulnerabilities with high severity
    "v_medium"                                  INT := 0; -- Number of vulnerabilities with medium severity
    "v_low"                                     INT := 0; -- Number of vulnerabilities with low severity
    "v_unassigned"                              INT := 0; -- Number of vulnerabilities with unassigned severity
    "v_findings_total"                          INT := 0; -- Total number of findings
    "v_findings_audited"                        INT := 0; -- Number of audited findings
    "v_findings_unaudited"                      INT := 0; -- Number of unaudited findings
    "v_findings_suppressed"                     INT := 0; -- Number of suppressed findings
    "v_policy_violations_total"                 INT := 0; -- Total number of policy violations
    "v_policy_violations_fail"                  INT := 0; -- Number of policy violations with level fail
    "v_policy_violations_warn"                  INT := 0; -- Number of policy violations with level warn
    "v_policy_violations_info"                  INT := 0; -- Number of policy violations with level info
    "v_policy_violations_audited"               INT := 0; -- Number of audited policy violations
    "v_policy_violations_unaudited"             INT := 0; -- Number of unaudited policy violations
    "v_policy_violations_license_total"         INT := 0; -- Total number of policy violations of type license
    "v_policy_violations_license_audited"       INT := 0; -- Number of audited policy violations of type license
    "v_policy_violations_license_unaudited"     INT := 0; -- Number of unaudited policy violations of type license
    "v_policy_violations_operational_total"     INT := 0; -- Total number of policy violations of type operational
    "v_policy_violations_operational_audited"   INT := 0; -- Number of audited policy violations of type operational
    "v_policy_violations_operational_unaudited" INT := 0; -- Number of unaudited policy violations of type operational
    "v_policy_violations_security_total"        INT := 0; -- Total number of policy violations of type security
    "v_policy_violations_security_audited"      INT := 0; -- Number of audited policy violations of type security
    "v_policy_violations_security_unaudited"    INT := 0; -- Number of unaudited policy violations of type security
    "v_existing_id"                             BIGINT; -- ID of the existing row that matches the data point calculated in this procedure
    "v_now"                                     DATE; -- The date to be set as last occurrence of this data point
    "v_foo"                                     RECORD;
BEGIN
    SELECT "ID", "PROJECT_ID" INTO "v_component" FROM "COMPONENT" WHERE "UUID" = "component_uuid";
    IF "v_component" IS NULL THEN
        RAISE EXCEPTION 'Component with UUID % does not exist', "component_uuid";
    END IF;

    FOR "v_vulnerability" IN SELECT "VULNID", "SOURCE", "SEVERITY", "CVSSV2BASESCORE", "CVSSV3BASESCORE"
                             FROM "VULNERABILITY" AS "V"
                                      INNER JOIN "COMPONENTS_VULNERABILITIES" AS "CV"
                                                 ON "CV"."COMPONENT_ID" = "v_component"."ID"
                                                     AND "CV"."VULNERABILITY_ID" = "V"."ID"
                             WHERE NOT EXISTS(SELECT 1
                                              FROM "ANALYSIS" AS "A"
                                              WHERE "A"."COMPONENT_ID" = "v_component"."ID"
                                                AND "A"."VULNERABILITY_ID" = "CV"."VULNERABILITY_ID"
                                                AND "A"."SUPPRESSED" = TRUE)
        LOOP
            -- TODO: Check aliases

            "v_vulnerabilities" := "v_vulnerabilities" + 1;

            SELECT "CALC_SEVERITY"(
                           "v_vulnerability"."SEVERITY",
                           "v_vulnerability"."CVSSV3BASESCORE",
                           "v_vulnerability"."CVSSV2BASESCORE")
            INTO "v_severity";

            IF "v_severity" = 'CRITICAL' THEN
                "v_critical" := "v_critical" + 1;
            ELSEIF "v_severity" = 'HIGH' THEN
                "v_high" := "v_high" + 1;
            ELSEIF "v_severity" = 'MEDIUM' THEN
                "v_medium" := "v_medium" + 1;
            ELSEIF "v_severity" = 'LOW' THEN
                "v_low" := "v_low" + 1;
            ELSE
                "v_unassigned" := "v_unassigned" + 1;
            END IF;

        END LOOP;

    SELECT COUNT(*)
    FROM "ANALYSIS" AS "A"
    WHERE "A"."COMPONENT_ID" = "v_component"."ID"
      AND "A"."SUPPRESSED" = FALSE
      AND "A"."STATE" != 'NOT_SET'
      AND "A"."STATE" != 'IN_TRIAGE'
    INTO "v_findings_audited";

    "v_findings_total" = "v_vulnerabilities";
    "v_findings_unaudited" = "v_findings_total" - "v_findings_audited";

    SELECT COUNT(*)
    FROM "ANALYSIS" AS "A"
    WHERE "A"."COMPONENT_ID" = "v_component"."ID"
      AND "A"."SUPPRESSED" = TRUE
    INTO "v_findings_suppressed";

    FOR "v_policy_violation" IN SELECT "PV"."TYPE", "P"."VIOLATIONSTATE"
                                FROM "POLICYVIOLATION" AS "PV"
                                         INNER JOIN "POLICYCONDITION" AS "PC" ON "PV"."POLICYCONDITION_ID" = "PC"."ID"
                                         INNER JOIN "POLICY" AS "P" ON "PC"."POLICY_ID" = "P"."ID"
        LOOP
            "v_policy_violations_total" := "v_policy_violations_total" + 1;

            IF "v_policy_violation"."TYPE" = 'LICENSE' THEN
                "v_policy_violations_license_total" := "v_policy_violations_license_total" + 1;
            ELSEIF "v_policy_violation"."TYPE" = 'OPERATIONAL' THEN
                "v_policy_violations_operational_total" := "v_policy_violations_operational_total" + 1;
            ELSEIF "v_policy_violation"."TYPE" = 'SECURITY' THEN
                "v_policy_violations_security_total" := "v_policy_violations_security_total" + 1;
            ELSE
                RAISE EXCEPTION 'Encountered invalid policy violation type %', "v_policy_violation"."TYPE";
            END IF;

            IF "v_policy_violation"."VIOLATIONSTATE" = 'FAIL' THEN
                "v_policy_violations_fail" := "v_policy_violations_fail" + 1;
            ELSEIF "v_policy_violation"."VIOLATIONSTATE" = 'WARN' THEN
                "v_policy_violations_warn" := "v_policy_violations_warn" + 1;
            ELSEIF "v_policy_violation"."VIOLATIONSTATE" = 'INFO' THEN
                "v_policy_violations_info" := "v_policy_violations_info" + 1;
            ELSE
                RAISE EXCEPTION 'Encountered invalid violation state %', "v_policy_violation"."VIOLATIONSTATE";
            end if;
        END LOOP;

    SELECT "PV"."TYPE", COUNT(*)
    FROM "VIOLATIONANALYSIS" AS "VA"
             INNER JOIN "POLICYVIOLATION" AS "PV" ON "PV"."ID" = "VA"."POLICYVIOLATION_ID"
    WHERE "VA"."COMPONENT_ID" = "v_component"."ID"
      AND "VA"."SUPPRESSED" = FALSE
      AND "VA"."STATE" != 'NOT_SET'
    GROUP BY "PV"."TYPE"
    INTO "v_foo";

    SELECT DISTINCT ON ("ID") "ID"
    FROM "DEPENDENCYMETRICS"
    WHERE "COMPONENT_ID" = "v_component"."ID"
      AND "VULNERABILITIES" = "v_vulnerabilities"
      AND "CRITICAL" = "v_critical"
      AND "HIGH" = "v_high"
      AND "MEDIUM" = "v_medium"
      AND "LOW" = "v_low"
      AND "UNASSIGNED_SEVERITY" = "v_unassigned"
      AND "FINDINGS_TOTAL" = "v_findings_total"
      AND "FINDINGS_AUDITED" = "v_findings_audited"
      AND "FINDINGS_UNAUDITED" = "v_findings_unaudited"
      AND "SUPPRESSED" = "v_findings_suppressed"
      AND "POLICYVIOLATIONS_TOTAL" = "v_policy_violations_total"
      AND "POLICYVIOLATIONS_FAIL" = "v_policy_violations_fail"
      AND "POLICYVIOLATIONS_WARN" = "v_policy_violations_warn"
      AND "POLICYVIOLATIONS_INFO" = "v_policy_violations_info"
      AND "POLICYVIOLATIONS_AUDITED" = "v_policy_violations_audited"
      AND "POLICYVIOLATIONS_UNAUDITED" = "v_policy_violations_unaudited"
      AND "POLICYVIOLATIONS_LICENSE_TOTAL" = "v_policy_violations_license_total"
      AND "POLICYVIOLATIONS_LICENSE_AUDITED" = "v_policy_violations_license_audited"
      AND "POLICYVIOLATIONS_LICENSE_UNAUDITED" = "v_policy_violations_license_unaudited"
      AND "POLICYVIOLATIONS_OPERATIONAL_TOTAL" = "v_policy_violations_operational_total"
      AND "POLICYVIOLATIONS_OPERATIONAL_AUDITED" = "v_policy_violations_operational_audited"
      AND "POLICYVIOLATIONS_OPERATIONAL_UNAUDITED" = "v_policy_violations_operational_unaudited"
      AND "POLICYVIOLATIONS_SECURITY_TOTAL" = "v_policy_violations_security_total"
      AND "POLICYVIOLATIONS_SECURITY_AUDITED" = "v_policy_violations_security_audited"
      AND "POLICYVIOLATIONS_SECURITY_UNAUDITED" = "v_policy_violations_security_unaudited"
    ORDER BY "ID", "LAST_OCCURRENCE" DESC
    LIMIT 1
    INTO "v_existing_id";

    "v_now" = NOW();
    IF "v_existing_id" IS NOT NULL THEN
        UPDATE "DEPENDENCYMETRICS" SET "LAST_OCCURRENCE" = "v_now" WHERE "ID" = "v_existing_id";
    ELSE
        INSERT INTO "DEPENDENCYMETRICS" ("COMPONENT_ID",
                                         "PROJECT_ID",
                                         "VULNERABILITIES",
                                         "CRITICAL",
                                         "HIGH",
                                         "MEDIUM",
                                         "LOW",
                                         "UNASSIGNED_SEVERITY",
                                         "FINDINGS_TOTAL",
                                         "FINDINGS_AUDITED",
                                         "FINDINGS_UNAUDITED",
                                         "SUPPRESSED",
                                         "POLICYVIOLATIONS_TOTAL",
                                         "POLICYVIOLATIONS_FAIL",
                                         "POLICYVIOLATIONS_WARN",
                                         "POLICYVIOLATIONS_INFO",
                                         "POLICYVIOLATIONS_AUDITED",
                                         "POLICYVIOLATIONS_UNAUDITED",
                                         "POLICYVIOLATIONS_LICENSE_TOTAL",
                                         "POLICYVIOLATIONS_LICENSE_AUDITED",
                                         "POLICYVIOLATIONS_LICENSE_UNAUDITED",
                                         "POLICYVIOLATIONS_OPERATIONAL_TOTAL",
                                         "POLICYVIOLATIONS_OPERATIONAL_AUDITED",
                                         "POLICYVIOLATIONS_OPERATIONAL_UNAUDITED",
                                         "POLICYVIOLATIONS_SECURITY_TOTAL",
                                         "POLICYVIOLATIONS_SECURITY_AUDITED",
                                         "POLICYVIOLATIONS_SECURITY_UNAUDITED",
                                         "RISKSCORE",
                                         "FIRST_OCCURRENCE",
                                         "LAST_OCCURRENCE")
        VALUES ("v_component"."ID",
                "v_component"."PROJECT_ID",
                "v_vulnerabilities",
                "v_critical",
                "v_high",
                "v_medium",
                "v_low",
                "v_unassigned",
                "v_findings_total",
                "v_findings_audited",
                "v_findings_unaudited",
                "v_findings_suppressed",
                "v_policy_violations_total",
                "v_policy_violations_fail",
                "v_policy_violations_warn",
                "v_policy_violations_info",
                "v_policy_violations_audited",
                "v_policy_violations_unaudited",
                "v_policy_violations_license_total",
                "v_policy_violations_license_audited",
                "v_policy_violations_license_unaudited",
                "v_policy_violations_operational_total",
                "v_policy_violations_operational_audited",
                "v_policy_violations_operational_unaudited",
                "v_policy_violations_security_total",
                "v_policy_violations_security_audited",
                "v_policy_violations_security_unaudited",
                "CALC_RISK_SCORE"("v_critical", "v_high", "v_medium", "v_low", "v_unassigned"),
                "v_now",
                "v_now");
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE "UPDATE_PROJECT_METRICS"(
    "project_uuid" VARCHAR(36)
)
    LANGUAGE "plpgsql"
AS
$$
DECLARE
    "v_project_id"     BIGINT;
    "v_component_uuid" VARCHAR;
    "v_aggregate"      RECORD;
    "v_existing_id"    BIGINT;
    "v_now"            DATE;
BEGIN
    SELECT "ID" FROM "PROJECT" WHERE "UUID" = "project_uuid" INTO "v_project_id";
    IF "v_project_id" IS NULL THEN
        RAISE EXCEPTION 'Project with UUID % does not exist', "project_uuid";
    END IF;

    -- TODO: Each
    FOR "v_component_uuid" IN SELECT "UUID" FROM "COMPONENT" WHERE "PROJECT_ID" = "v_project_id"
        LOOP
            RAISE NOTICE 'Updating metrics of component %', "v_component_uuid";
            CALL "UPDATE_COMPONENT_METRICS"("v_component_uuid");
        END LOOP;

    SELECT COUNT(*)::INT                                          AS "COMPONENTS",
           SUM(CASE WHEN "VULNERABILITIES" > 0 THEN 1 ELSE 0 END) AS "VULNERABLECOMPONENTS",
           SUM("VULNERABILITIES")::INT                            AS "VULNERABILITIES",
           SUM("CRITICAL")::INT                                   AS "CRITICAL",
           SUM("HIGH")::INT                                       AS "HIGH",
           SUM("MEDIUM")::INT                                     AS "MEDIUM",
           SUM("LOW")::INT                                        AS "LOW",
           SUM("UNASSIGNED_SEVERITY")::INT                        AS "UNASSIGNED_SEVERITY",
           SUM("FINDINGS_TOTAL")::INT                             AS "FINDINGS_TOTAL",
           SUM("FINDINGS_AUDITED")::INT                           AS "FINDINGS_AUDITED",
           SUM("FINDINGS_UNAUDITED")::INT                         AS "FINDINGS_UNAUDITED",
           SUM("SUPPRESSED")::INT                                 AS "SUPPRESSED",
           SUM("POLICYVIOLATIONS_TOTAL")::INT                     AS "POLICYVIOLATIONS_TOTAL",
           SUM("POLICYVIOLATIONS_FAIL")::INT                      AS "POLICYVIOLATIONS_FAIL",
           SUM("POLICYVIOLATIONS_WARN")::INT                      AS "POLICYVIOLATIONS_WARN",
           SUM("POLICYVIOLATIONS_INFO")::INT                      AS "POLICYVIOLATIONS_INFO",
           SUM("POLICYVIOLATIONS_AUDITED")::INT                   AS "POLICYVIOLATIONS_AUDITED",
           SUM("POLICYVIOLATIONS_UNAUDITED")::INT                 AS "POLICYVIOLATIONS_UNAUDITED",
           SUM("POLICYVIOLATIONS_LICENSE_TOTAL")::INT             AS "POLICYVIOLATIONS_LICENSE_TOTAL",
           SUM("POLICYVIOLATIONS_LICENSE_AUDITED")::INT           AS "POLICYVIOLATIONS_LICENSE_AUDITED",
           SUM("POLICYVIOLATIONS_LICENSE_UNAUDITED")::INT         AS "POLICYVIOLATIONS_LICENSE_UNAUDITED",
           SUM("POLICYVIOLATIONS_OPERATIONAL_TOTAL")::INT         AS "POLICYVIOLATIONS_OPERATIONAL_TOTAL",
           SUM("POLICYVIOLATIONS_OPERATIONAL_AUDITED")::INT       AS "POLICYVIOLATIONS_OPERATIONAL_AUDITED",
           SUM("POLICYVIOLATIONS_OPERATIONAL_UNAUDITED")::INT     AS "POLICYVIOLATIONS_OPERATIONAL_UNAUDITED",
           SUM("POLICYVIOLATIONS_SECURITY_TOTAL")::INT            AS "POLICYVIOLATIONS_SECURITY_TOTAL",
           SUM("POLICYVIOLATIONS_SECURITY_AUDITED")::INT          AS "POLICYVIOLATIONS_SECURITY_AUDITED",
           SUM("POLICYVIOLATIONS_SECURITY_UNAUDITED")::INT        AS "POLICYVIOLATIONS_SECURITY_UNAUDITED"
    FROM (SELECT DISTINCT ON ("DM"."COMPONENT_ID") *
          FROM "DEPENDENCYMETRICS" AS "DM"
          WHERE "PROJECT_ID" = "v_project_id"
          ORDER BY "DM"."COMPONENT_ID", "DM"."LAST_OCCURRENCE" DESC) AS "LATEST_COMPONENT_METRICS"
    INTO "v_aggregate";

    SELECT "ID"
    FROM "PROJECTMETRICS"
    WHERE "PROJECT_ID" = "v_project_id"
      AND "COMPONENTS" = "v_aggregate"."COMPONENTS"
      AND "VULNERABLECOMPONENTS" = "v_aggregate"."VULNERABLECOMPONENTS"
      AND "VULNERABILITIES" = "v_aggregate"."VULNERABILITIES"
      AND "CRITICAL" = "v_aggregate"."CRITICAL"
      AND "HIGH" = "v_aggregate"."HIGH"
      AND "MEDIUM" = "v_aggregate"."MEDIUM"
      AND "LOW" = "v_aggregate"."LOW"
      AND "UNASSIGNED_SEVERITY" = "v_aggregate"."UNASSIGNED_SEVERITY"
      AND "FINDINGS_TOTAL" = "v_aggregate"."FINDINGS_TOTAL"
      AND "FINDINGS_AUDITED" = "v_aggregate"."FINDINGS_AUDITED"
      AND "FINDINGS_UNAUDITED" = "v_aggregate"."FINDINGS_UNAUDITED"
      AND "SUPPRESSED" = "v_aggregate"."SUPPRESSED"
      AND "POLICYVIOLATIONS_TOTAL" = "v_aggregate"."POLICYVIOLATIONS_TOTAL"
      AND "POLICYVIOLATIONS_FAIL" = "v_aggregate"."POLICYVIOLATIONS_FAIL"
      AND "POLICYVIOLATIONS_WARN" = "v_aggregate"."POLICYVIOLATIONS_WARN"
      AND "POLICYVIOLATIONS_INFO" = "v_aggregate"."POLICYVIOLATIONS_INFO"
      AND "POLICYVIOLATIONS_AUDITED" = "v_aggregate"."POLICYVIOLATIONS_AUDITED"
      AND "POLICYVIOLATIONS_UNAUDITED" = "v_aggregate"."POLICYVIOLATIONS_UNAUDITED"
      AND "POLICYVIOLATIONS_LICENSE_TOTAL" = "v_aggregate"."POLICYVIOLATIONS_LICENSE_TOTAL"
      AND "POLICYVIOLATIONS_LICENSE_AUDITED" = "v_aggregate"."POLICYVIOLATIONS_LICENSE_AUDITED"
      AND "POLICYVIOLATIONS_LICENSE_UNAUDITED" = "v_aggregate"."POLICYVIOLATIONS_LICENSE_UNAUDITED"
      AND "POLICYVIOLATIONS_OPERATIONAL_TOTAL" = "v_aggregate"."POLICYVIOLATIONS_OPERATIONAL_TOTAL"
      AND "POLICYVIOLATIONS_OPERATIONAL_AUDITED" = "v_aggregate"."POLICYVIOLATIONS_OPERATIONAL_AUDITED"
      AND "POLICYVIOLATIONS_OPERATIONAL_UNAUDITED" = "v_aggregate"."POLICYVIOLATIONS_OPERATIONAL_UNAUDITED"
      AND "POLICYVIOLATIONS_SECURITY_TOTAL" = "v_aggregate"."POLICYVIOLATIONS_SECURITY_TOTAL"
      AND "POLICYVIOLATIONS_SECURITY_AUDITED" = "v_aggregate"."POLICYVIOLATIONS_SECURITY_AUDITED"
      AND "POLICYVIOLATIONS_SECURITY_UNAUDITED" = "v_aggregate"."POLICYVIOLATIONS_SECURITY_UNAUDITED"
    ORDER BY "LAST_OCCURRENCE" DESC
    LIMIT 1
    INTO "v_existing_id";

    "v_now" = NOW();
    IF "v_existing_id" IS NOT NULL THEN
        UPDATE "PROJECTMETRICS" SET "LAST_OCCURRENCE" = "v_now" WHERE "ID" = "v_existing_id";
    ELSE
        INSERT INTO "PROJECTMETRICS" ("PROJECT_ID",
                                      "COMPONENTS",
                                      "VULNERABLECOMPONENTS",
                                      "VULNERABILITIES",
                                      "CRITICAL",
                                      "HIGH",
                                      "MEDIUM",
                                      "LOW",
                                      "UNASSIGNED_SEVERITY",
                                      "FINDINGS_TOTAL",
                                      "FINDINGS_AUDITED",
                                      "FINDINGS_UNAUDITED",
                                      "SUPPRESSED",
                                      "POLICYVIOLATIONS_TOTAL",
                                      "POLICYVIOLATIONS_FAIL",
                                      "POLICYVIOLATIONS_WARN",
                                      "POLICYVIOLATIONS_INFO",
                                      "POLICYVIOLATIONS_AUDITED",
                                      "POLICYVIOLATIONS_UNAUDITED",
                                      "POLICYVIOLATIONS_LICENSE_TOTAL",
                                      "POLICYVIOLATIONS_LICENSE_AUDITED",
                                      "POLICYVIOLATIONS_LICENSE_UNAUDITED",
                                      "POLICYVIOLATIONS_OPERATIONAL_TOTAL",
                                      "POLICYVIOLATIONS_OPERATIONAL_AUDITED",
                                      "POLICYVIOLATIONS_OPERATIONAL_UNAUDITED",
                                      "POLICYVIOLATIONS_SECURITY_TOTAL",
                                      "POLICYVIOLATIONS_SECURITY_AUDITED",
                                      "POLICYVIOLATIONS_SECURITY_UNAUDITED",
                                      "RISKSCORE",
                                      "FIRST_OCCURRENCE",
                                      "LAST_OCCURRENCE")
        VALUES ("v_project_id",
                "v_aggregate"."COMPONENTS",
                "v_aggregate"."VULNERABLECOMPONENTS",
                "v_aggregate"."VULNERABILITIES",
                "v_aggregate"."CRITICAL",
                "v_aggregate"."HIGH",
                "v_aggregate"."MEDIUM",
                "v_aggregate"."LOW",
                "v_aggregate"."UNASSIGNED_SEVERITY",
                "v_aggregate"."FINDINGS_TOTAL",
                "v_aggregate"."FINDINGS_AUDITED",
                "v_aggregate"."FINDINGS_UNAUDITED",
                "v_aggregate"."SUPPRESSED",
                "v_aggregate"."POLICYVIOLATIONS_TOTAL",
                "v_aggregate"."POLICYVIOLATIONS_FAIL",
                "v_aggregate"."POLICYVIOLATIONS_WARN",
                "v_aggregate"."POLICYVIOLATIONS_INFO",
                "v_aggregate"."POLICYVIOLATIONS_SECURITY_AUDITED",
                "v_aggregate"."POLICYVIOLATIONS_SECURITY_UNAUDITED",
                "v_aggregate"."POLICYVIOLATIONS_LICENSE_TOTAL",
                "v_aggregate"."POLICYVIOLATIONS_LICENSE_AUDITED",
                "v_aggregate"."POLICYVIOLATIONS_LICENSE_UNAUDITED",
                "v_aggregate"."POLICYVIOLATIONS_OPERATIONAL_TOTAL",
                "v_aggregate"."POLICYVIOLATIONS_OPERATIONAL_AUDITED",
                "v_aggregate"."POLICYVIOLATIONS_OPERATIONAL_UNAUDITED",
                "v_aggregate"."POLICYVIOLATIONS_SECURITY_TOTAL",
                "v_aggregate"."POLICYVIOLATIONS_SECURITY_AUDITED",
                "v_aggregate"."POLICYVIOLATIONS_SECURITY_UNAUDITED",
                "CALC_RISK_SCORE"("v_aggregate"."CRITICAL",
                                  "v_aggregate"."HIGH",
                                  "v_aggregate"."MEDIUM",
                                  "v_aggregate"."LOW",
                                  "v_aggregate"."UNASSIGNED_SEVERITY"),
                "v_now",
                "v_now");
    END IF;
end;
$$;

CREATE OR REPLACE PROCEDURE "UPDATE_PORTFOLIO_METRICS"()
    LANGUAGE "plpgsql"
AS
$$
DECLARE
    "v_aggregate"   RECORD;
    "v_existing_id" BIGINT;
    "v_now"         DATE;
BEGIN
    SELECT COUNT(*)::INT                                          AS "PROJECTS",
           SUM(CASE WHEN "VULNERABILITIES" > 0 THEN 1 ELSE 0 END) AS "VULNERABLEPROJECTS",
           SUM("COMPONENTS")::INT                                 AS "COMPONENTS",
           SUM("VULNERABLECOMPONENTS")::INT                       AS "VULNERABLECOMPONENTS",
           SUM("VULNERABILITIES")::INT                            AS "VULNERABILITIES",
           SUM("CRITICAL")::INT                                   AS "CRITICAL",
           SUM("HIGH")::INT                                       AS "HIGH",
           SUM("MEDIUM")::INT                                     AS "MEDIUM",
           SUM("LOW")::INT                                        AS "LOW",
           SUM("UNASSIGNED_SEVERITY")::INT                        AS "UNASSIGNED_SEVERITY",
           SUM("FINDINGS_TOTAL")::INT                             AS "FINDINGS_TOTAL",
           SUM("FINDINGS_AUDITED")::INT                           AS "FINDINGS_AUDITED",
           SUM("FINDINGS_UNAUDITED")::INT                         AS "FINDINGS_UNAUDITED",
           SUM("SUPPRESSED")::INT                                 AS "SUPPRESSED",
           SUM("POLICYVIOLATIONS_TOTAL")::INT                     AS "POLICYVIOLATIONS_TOTAL",
           SUM("POLICYVIOLATIONS_FAIL")::INT                      AS "POLICYVIOLATIONS_FAIL",
           SUM("POLICYVIOLATIONS_WARN")::INT                      AS "POLICYVIOLATIONS_WARN",
           SUM("POLICYVIOLATIONS_INFO")::INT                      AS "POLICYVIOLATIONS_INFO",
           SUM("POLICYVIOLATIONS_AUDITED")::INT                   AS "POLICYVIOLATIONS_AUDITED",
           SUM("POLICYVIOLATIONS_UNAUDITED")::INT                 AS "POLICYVIOLATIONS_UNAUDITED",
           SUM("POLICYVIOLATIONS_LICENSE_TOTAL")::INT             AS "POLICYVIOLATIONS_LICENSE_TOTAL",
           SUM("POLICYVIOLATIONS_LICENSE_AUDITED")::INT           AS "POLICYVIOLATIONS_LICENSE_AUDITED",
           SUM("POLICYVIOLATIONS_LICENSE_UNAUDITED")::INT         AS "POLICYVIOLATIONS_LICENSE_UNAUDITED",
           SUM("POLICYVIOLATIONS_OPERATIONAL_TOTAL")::INT         AS "POLICYVIOLATIONS_OPERATIONAL_TOTAL",
           SUM("POLICYVIOLATIONS_OPERATIONAL_AUDITED")::INT       AS "POLICYVIOLATIONS_OPERATIONAL_AUDITED",
           SUM("POLICYVIOLATIONS_OPERATIONAL_UNAUDITED")::INT     AS "POLICYVIOLATIONS_OPERATIONAL_UNAUDITED",
           SUM("POLICYVIOLATIONS_SECURITY_TOTAL")::INT            AS "POLICYVIOLATIONS_SECURITY_TOTAL",
           SUM("POLICYVIOLATIONS_SECURITY_AUDITED")::INT          AS "POLICYVIOLATIONS_SECURITY_AUDITED",
           SUM("POLICYVIOLATIONS_SECURITY_UNAUDITED")::INT        AS "POLICYVIOLATIONS_SECURITY_UNAUDITED"
    FROM (SELECT DISTINCT ON ("PM"."PROJECT_ID") *
          FROM "PROJECTMETRICS" AS "PM"
          ORDER BY "PM"."PROJECT_ID", "PM"."LAST_OCCURRENCE" DESC) AS "LATEST_PROJECT_METRICS"
    INTO "v_aggregate";

    SELECT "ID"
    FROM "PORTFOLIOMETRICS"
    WHERE "PROJECTS" = "v_aggregate"."PROJECTS"
      AND "VULNERABLEPROJECTS" = "v_aggregate"."VULNERABLEPROJECTS"
      AND "COMPONENTS" = "v_aggregate"."COMPONENTS"
      AND "VULNERABLECOMPONENTS" = "v_aggregate"."VULNERABLECOMPONENTS"
      AND "VULNERABILITIES" = "v_aggregate"."VULNERABILITIES"
      AND "CRITICAL" = "v_aggregate"."CRITICAL"
      AND "HIGH" = "v_aggregate"."HIGH"
      AND "MEDIUM" = "v_aggregate"."MEDIUM"
      AND "LOW" = "v_aggregate"."LOW"
      AND "UNASSIGNED_SEVERITY" = "v_aggregate"."UNASSIGNED_SEVERITY"
      AND "FINDINGS_TOTAL" = "v_aggregate"."FINDINGS_TOTAL"
      AND "FINDINGS_AUDITED" = "v_aggregate"."FINDINGS_AUDITED"
      AND "FINDINGS_UNAUDITED" = "v_aggregate"."FINDINGS_UNAUDITED"
      AND "SUPPRESSED" = "v_aggregate"."SUPPRESSED"
      AND "POLICYVIOLATIONS_TOTAL" = "v_aggregate"."POLICYVIOLATIONS_TOTAL"
      AND "POLICYVIOLATIONS_FAIL" = "v_aggregate"."POLICYVIOLATIONS_FAIL"
      AND "POLICYVIOLATIONS_WARN" = "v_aggregate"."POLICYVIOLATIONS_WARN"
      AND "POLICYVIOLATIONS_INFO" = "v_aggregate"."POLICYVIOLATIONS_INFO"
      AND "POLICYVIOLATIONS_AUDITED" = "v_aggregate"."POLICYVIOLATIONS_AUDITED"
      AND "POLICYVIOLATIONS_UNAUDITED" = "v_aggregate"."POLICYVIOLATIONS_UNAUDITED"
      AND "POLICYVIOLATIONS_LICENSE_TOTAL" = "v_aggregate"."POLICYVIOLATIONS_LICENSE_TOTAL"
      AND "POLICYVIOLATIONS_LICENSE_AUDITED" = "v_aggregate"."POLICYVIOLATIONS_LICENSE_AUDITED"
      AND "POLICYVIOLATIONS_LICENSE_UNAUDITED" = "v_aggregate"."POLICYVIOLATIONS_LICENSE_UNAUDITED"
      AND "POLICYVIOLATIONS_OPERATIONAL_TOTAL" = "v_aggregate"."POLICYVIOLATIONS_OPERATIONAL_TOTAL"
      AND "POLICYVIOLATIONS_OPERATIONAL_AUDITED" = "v_aggregate"."POLICYVIOLATIONS_OPERATIONAL_AUDITED"
      AND "POLICYVIOLATIONS_OPERATIONAL_UNAUDITED" = "v_aggregate"."POLICYVIOLATIONS_OPERATIONAL_UNAUDITED"
      AND "POLICYVIOLATIONS_SECURITY_TOTAL" = "v_aggregate"."POLICYVIOLATIONS_SECURITY_TOTAL"
      AND "POLICYVIOLATIONS_SECURITY_AUDITED" = "v_aggregate"."POLICYVIOLATIONS_SECURITY_AUDITED"
      AND "POLICYVIOLATIONS_SECURITY_UNAUDITED" = "v_aggregate"."POLICYVIOLATIONS_SECURITY_UNAUDITED"
    ORDER BY "LAST_OCCURRENCE" DESC
    LIMIT 1
    INTO "v_existing_id";

    "v_now" = NOW();
    IF "v_existing_id" IS NOT NULL THEN
        UPDATE "PORTFOLIOMETRICS" SET "LAST_OCCURRENCE" = "v_now" WHERE "ID" = "v_existing_id";
    ELSE
        INSERT INTO "PORTFOLIOMETRICS" ("PROJECTS",
                                        "VULNERABLEPROJECTS",
                                        "COMPONENTS",
                                        "VULNERABLECOMPONENTS",
                                        "VULNERABILITIES",
                                        "CRITICAL",
                                        "HIGH",
                                        "MEDIUM",
                                        "LOW",
                                        "UNASSIGNED_SEVERITY",
                                        "FINDINGS_TOTAL",
                                        "FINDINGS_AUDITED",
                                        "FINDINGS_UNAUDITED",
                                        "SUPPRESSED",
                                        "POLICYVIOLATIONS_TOTAL",
                                        "POLICYVIOLATIONS_FAIL",
                                        "POLICYVIOLATIONS_WARN",
                                        "POLICYVIOLATIONS_INFO",
                                        "POLICYVIOLATIONS_AUDITED",
                                        "POLICYVIOLATIONS_UNAUDITED",
                                        "POLICYVIOLATIONS_LICENSE_TOTAL",
                                        "POLICYVIOLATIONS_LICENSE_AUDITED",
                                        "POLICYVIOLATIONS_LICENSE_UNAUDITED",
                                        "POLICYVIOLATIONS_OPERATIONAL_TOTAL",
                                        "POLICYVIOLATIONS_OPERATIONAL_AUDITED",
                                        "POLICYVIOLATIONS_OPERATIONAL_UNAUDITED",
                                        "POLICYVIOLATIONS_SECURITY_TOTAL",
                                        "POLICYVIOLATIONS_SECURITY_AUDITED",
                                        "POLICYVIOLATIONS_SECURITY_UNAUDITED",
                                        "RISKSCORE",
                                        "FIRST_OCCURRENCE",
                                        "LAST_OCCURRENCE")
        VALUES ("v_aggregate"."PROJECTS",
                "v_aggregate"."VULNERABLEPROJECTS",
                "v_aggregate"."COMPONENTS",
                "v_aggregate"."VULNERABLECOMPONENTS",
                "v_aggregate"."VULNERABILITIES",
                "v_aggregate"."CRITICAL",
                "v_aggregate"."HIGH",
                "v_aggregate"."MEDIUM",
                "v_aggregate"."LOW",
                "v_aggregate"."UNASSIGNED_SEVERITY",
                "v_aggregate"."FINDINGS_TOTAL",
                "v_aggregate"."FINDINGS_AUDITED",
                "v_aggregate"."FINDINGS_UNAUDITED",
                "v_aggregate"."SUPPRESSED",
                "v_aggregate"."POLICYVIOLATIONS_TOTAL",
                "v_aggregate"."POLICYVIOLATIONS_FAIL",
                "v_aggregate"."POLICYVIOLATIONS_WARN",
                "v_aggregate"."POLICYVIOLATIONS_INFO",
                "v_aggregate"."POLICYVIOLATIONS_SECURITY_AUDITED",
                "v_aggregate"."POLICYVIOLATIONS_SECURITY_UNAUDITED",
                "v_aggregate"."POLICYVIOLATIONS_LICENSE_TOTAL",
                "v_aggregate"."POLICYVIOLATIONS_LICENSE_AUDITED",
                "v_aggregate"."POLICYVIOLATIONS_LICENSE_UNAUDITED",
                "v_aggregate"."POLICYVIOLATIONS_OPERATIONAL_TOTAL",
                "v_aggregate"."POLICYVIOLATIONS_OPERATIONAL_AUDITED",
                "v_aggregate"."POLICYVIOLATIONS_OPERATIONAL_UNAUDITED",
                "v_aggregate"."POLICYVIOLATIONS_SECURITY_TOTAL",
                "v_aggregate"."POLICYVIOLATIONS_SECURITY_AUDITED",
                "v_aggregate"."POLICYVIOLATIONS_SECURITY_UNAUDITED",
                "CALC_RISK_SCORE"("v_aggregate"."CRITICAL",
                                  "v_aggregate"."HIGH",
                                  "v_aggregate"."MEDIUM",
                                  "v_aggregate"."LOW",
                                  "v_aggregate"."UNASSIGNED_SEVERITY"),
                "v_now",
                "v_now");
    END IF;
END;
$$;
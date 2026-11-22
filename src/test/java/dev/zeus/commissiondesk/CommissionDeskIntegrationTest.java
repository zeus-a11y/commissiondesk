package dev.zeus.commissiondesk;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.sql.Date;
import java.time.Duration;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.Order;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestInstance;
import org.junit.jupiter.api.TestMethodOrder;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.testcontainers.oracle.OracleContainer;

/**
 * End-to-end against a real Oracle Database 23: Flyway migrations, the PL/SQL packages, the
 * report views and the REST API. Uses Testcontainers, or an existing database if TEST_DB_URL is set.
 * Loads a small seeded book dated 21 Nov 2026 with history approved to September.
 */
@SpringBootTest(properties = {"commissiondesk.seed-demo-data=false", "commissiondesk.as-of=2026-11-21"})
@AutoConfigureMockMvc
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class CommissionDeskIntegrationTest {

  static final String EXTERNAL = System.getenv("TEST_DB_URL");
  static OracleContainer oracle;

  @DynamicPropertySource
  static void database(DynamicPropertyRegistry registry) throws Exception {
    if (EXTERNAL != null && !EXTERNAL.isBlank()) {
      registry.add("spring.datasource.url", () -> EXTERNAL);
    } else {
      // faststart ships a ready database; give it time on slow machines all the same
      oracle = new OracleContainer("gvenzl/oracle-free:23-slim-faststart")
          .withUsername("commission").withPassword("commission")
          .withStartupTimeout(Duration.ofMinutes(5));
      oracle.start();
      // the container's app user lacks CREATE JOB, which the scheduler migration needs
      oracle.execInContainer("bash", "-c",
          "printf 'ALTER SESSION SET CONTAINER=FREEPDB1;\\nGRANT CREATE JOB TO commission;\\n' | sqlplus -s / as sysdba");
      registry.add("spring.datasource.url", oracle::getJdbcUrl);
    }
    registry.add("spring.datasource.username", () -> "commission");
    registry.add("spring.datasource.password", () -> "commission");
  }

  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate jdbc;

  @BeforeAll
  void loadBook() {
    for (String t : List.of("commission_txn", "commission_exception", "agent_statement", "commission_run",
        "premium_receipt", "policy", "agent_audit")) {
      jdbc.update("DELETE FROM " + t);
    }
    jdbc.update("UPDATE agent SET parent_code = NULL");
    jdbc.update("DELETE FROM agent");
    jdbc.update("BEGIN pkg_demo_data.load_book(?, ?, ?); END;", Date.valueOf(LocalDate.of(2026, 11, 21)), 1200, 42);
    jdbc.update("BEGIN pkg_demo_data.run_history(?); END;", Date.valueOf(LocalDate.of(2026, 10, 1)));
  }

  @Test
  @Order(1)
  void historyIsApprovedAndEveryRunReconciles() {
    List<Map<String, Object>> runs = jdbc.queryForList("SELECT * FROM v_run_summary ORDER BY period");
    assertThat(runs).hasSizeGreaterThan(30);
    assertThat(runs).allSatisfy(r -> assertThat(r.get("STATUS")).isEqualTo("APPROVED"));

    // run total = sum of its postings = sum of what its statements earned (before brought-forward)
    List<Map<String, Object>> broken = jdbc.queryForList("""
        SELECT r.run_id
          FROM commission_run r
         WHERE r.gross_amount <> (SELECT NVL(SUM(amount), 0) FROM commission_txn t WHERE t.run_id = r.run_id)
            OR r.gross_amount <> (SELECT NVL(SUM(base_amount + override_amount + bonus_amount + clawback_amount), 0)
                                    FROM agent_statement s WHERE s.run_id = r.run_id)
        """);
    assertThat(broken).isEmpty();

    // statement arithmetic: taxable - TDS = net, and a debit is never paid out
    Integer bad = jdbc.queryForObject("""
        SELECT COUNT(*) FROM agent_statement
         WHERE net_payable <> taxable_amount - tds_amount
            OR taxable_amount <> GREATEST(base_amount + override_amount + bonus_amount + clawback_amount + brought_forward, 0)
            OR carry_forward <> LEAST(base_amount + override_amount + bonus_amount + clawback_amount + brought_forward, 0)
        """, Integer.class);
    assertThat(bad).isZero();
  }

  @Test
  @Order(2)
  void baseCommissionMatchesAnIndependentRecomputation() {
    // Recompute every BASE posting in Java from the raw rate table and compare with the PL/SQL.
    List<Map<String, Object>> rates = jdbc.queryForList("SELECT * FROM commission_rate");
    List<Map<String, Object>> postings = jdbc.queryForList("""
        SELECT p.product_code, r.policy_year, r.due_date, r.amount, t.rate_pct, t.amount AS commission
          FROM commission_txn t
          JOIN premium_receipt r ON r.receipt_id = t.receipt_id
          JOIN policy p ON p.policy_no = r.policy_no
         WHERE t.txn_type = 'BASE'
        """);
    assertThat(postings).hasSizeGreaterThan(1000);
    for (Map<String, Object> row : postings) {
      LocalDate due = ((java.sql.Timestamp) row.get("DUE_DATE")).toLocalDateTime().toLocalDate();
      int year = ((Number) row.get("POLICY_YEAR")).intValue();
      BigDecimal rate = rates.stream()
          .filter(r -> r.get("PRODUCT_CODE").equals(row.get("PRODUCT_CODE")))
          .filter(r -> year >= ((Number) r.get("YEAR_FROM")).intValue() && year <= ((Number) r.get("YEAR_TO")).intValue())
          .filter(r -> !due.isBefore(((java.sql.Timestamp) r.get("EFFECTIVE_FROM")).toLocalDateTime().toLocalDate())
              && due.isBefore(((java.sql.Timestamp) r.get("EFFECTIVE_TO")).toLocalDateTime().toLocalDate()))
          .map(r -> (BigDecimal) r.get("RATE_PCT"))
          .findFirst().orElseThrow();
      BigDecimal expected = ((BigDecimal) row.get("AMOUNT")).multiply(rate).divide(BigDecimal.valueOf(100), 2, RoundingMode.HALF_UP);
      assertThat((BigDecimal) row.get("COMMISSION")).isEqualByComparingTo(expected);
    }
  }

  @Test
  @Order(3)
  void calculateApproveAndLockOctoberThroughTheApi() throws Exception {
    String body = mvc.perform(post("/api/runs").contentType(MediaType.APPLICATION_JSON).content("{\"period\":\"2026-10\"}"))
        .andExpect(status().isCreated())
        .andExpect(jsonPath("$.STATUS").value("CALCULATED"))
        .andReturn().getResponse().getContentAsString();
    Long runId = jdbc.queryForObject("SELECT run_id FROM commission_run WHERE period = DATE '2026-10-01'", Long.class);
    assertThat(body).contains("\"RUN_ID\":" + runId);

    mvc.perform(get("/api/runs/" + runId + "/statements").param("branch", "Thane"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$[0].BRANCH").value("Thane"))
        .andExpect(jsonPath("$[0].BRANCH_RANK").value(1));

    // November cannot run before October is approved
    mvc.perform(post("/api/runs").contentType(MediaType.APPLICATION_JSON).content("{\"period\":\"2026-11\"}"))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.oraCode").value("ORA-20003"));

    mvc.perform(post("/api/runs/" + runId + "/approve").contentType(MediaType.APPLICATION_JSON).content("{\"approvedBy\":\"ops.lead\"}"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.STATUS").value("APPROVED"))
        .andExpect(jsonPath("$.APPROVED_BY").value("ops.lead"));

    // an approved month is locked, and the PL/SQL message reaches the client without the stack
    mvc.perform(post("/api/runs").contentType(MediaType.APPLICATION_JSON).content("{\"period\":\"2026-10\"}"))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.oraCode").value("ORA-20001"))
        .andExpect(jsonPath("$.detail").value("Oct 2026 is approved and locked"));
  }

  @Test
  @Order(4)
  void badRequestsAreRejectedCleanly() throws Exception {
    mvc.perform(post("/api/runs").contentType(MediaType.APPLICATION_JSON).content("{\"period\":\"2026-13\"}"))
        .andExpect(status().isBadRequest());
    mvc.perform(post("/api/runs").contentType(MediaType.APPLICATION_JSON).content("{\"period\":\"2027-01\"}"))
        .andExpect(status().isBadRequest())
        .andExpect(jsonPath("$.oraCode").value("ORA-20002"));
    mvc.perform(post("/api/runs").contentType(MediaType.APPLICATION_JSON).content("{not json"))
        .andExpect(status().isBadRequest());
    mvc.perform(get("/api/runs/999999")).andExpect(status().isNotFound());
    mvc.perform(get("/api/agents/NOPE")).andExpect(status().isNotFound());
  }

  @Test
  @Order(5)
  void teamTreeWalksTheHierarchy() throws Exception {
    // a branch manager has 3 seniors with 5 advisors each: 19 people including themselves
    mvc.perform(get("/api/agents/M1"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.AGENT_LEVEL").value("MANAGER"))
        .andExpect(jsonPath("$.team.length()").value(19))
        .andExpect(jsonPath("$.team[0].DEPTH").value(1))
        .andExpect(jsonPath("$.team[1].DEPTH").value(2))
        .andExpect(jsonPath("$.team[2].DEPTH").value(3));
  }

  @Test
  @Order(6)
  void exceptionsQueueHoldsWhatTheRunCouldNotPay() {
    Map<String, Object> counts = jdbc.queryForMap("""
        SELECT SUM(CASE WHEN message LIKE 'No commission rate%' THEN 1 ELSE 0 END) AS no_rate,
               SUM(CASE WHEN message LIKE 'Agent A232 left%' THEN 1 ELSE 0 END) AS orphan
          FROM commission_exception
        """);
    assertThat(((Number) counts.get("NO_RATE")).intValue()).isPositive();
    assertThat(((Number) counts.get("ORPHAN")).intValue()).isPositive();
    // and nothing in the queue was also paid
    Integer paidAnyway = jdbc.queryForObject("""
        SELECT COUNT(*) FROM commission_exception e
         WHERE EXISTS (SELECT 1 FROM commission_txn t WHERE t.receipt_id = e.receipt_id AND t.txn_type = 'BASE')
        """, Integer.class);
    assertThat(paidAnyway).isZero();
  }
}

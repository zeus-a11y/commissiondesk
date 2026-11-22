package dev.zeus.commissiondesk;

import java.sql.Date;
import java.sql.Types;
import java.time.LocalDate;
import java.time.YearMonth;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import javax.sql.DataSource;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.core.SqlOutParameter;
import org.springframework.jdbc.core.SqlParameter;
import org.springframework.jdbc.core.simple.SimpleJdbcCall;
import org.springframework.stereotype.Repository;

/**
 * Thin data access over the database. The business rules live in PL/SQL (pkg_commission);
 * Java calls the procedures and reads the report views. Every query is parameterised.
 */
@Repository
public class CommissionRepository {

  private final NamedParameterJdbcTemplate jdbc;
  private final SimpleJdbcCall calculate;
  private final SimpleJdbcCall approve;

  public CommissionRepository(DataSource dataSource, NamedParameterJdbcTemplate jdbc) {
    this.jdbc = jdbc;
    // explicit parameter lists: no metadata lookups against Oracle's dictionary on every call
    this.calculate = new SimpleJdbcCall(dataSource)
        .withCatalogName("PKG_COMMISSION").withProcedureName("CALCULATE")
        .withoutProcedureColumnMetaDataAccess()
        .declareParameters(
            new SqlParameter("P_PERIOD", Types.DATE),
            new SqlOutParameter("P_RUN_ID", Types.NUMERIC),
            new SqlParameter("P_TODAY", Types.DATE));
    this.approve = new SimpleJdbcCall(dataSource)
        .withCatalogName("PKG_COMMISSION").withProcedureName("APPROVE")
        .withoutProcedureColumnMetaDataAccess()
        .declareParameters(
            new SqlParameter("P_RUN_ID", Types.NUMERIC),
            new SqlParameter("P_BY", Types.VARCHAR));
  }

  public long calculate(YearMonth period, LocalDate today) {
    Map<String, Object> out = calculate.execute(new MapSqlParameterSource()
        .addValue("P_PERIOD", Date.valueOf(period.atDay(1)))
        .addValue("P_TODAY", Date.valueOf(today)));
    return ((Number) out.get("P_RUN_ID")).longValue();
  }

  public void approve(long runId, String by) {
    approve.execute(new MapSqlParameterSource().addValue("P_RUN_ID", runId).addValue("P_BY", by));
  }

  public List<Map<String, Object>> runs() {
    return jdbc.queryForList("SELECT * FROM v_run_summary ORDER BY period DESC", Map.of());
  }

  public Optional<Map<String, Object>> run(long runId) {
    return jdbc.queryForList("SELECT * FROM v_run_summary WHERE run_id = :id", Map.of("id", runId)).stream().findFirst();
  }

  public List<Map<String, Object>> exceptions(long runId) {
    return jdbc.queryForList("""
        SELECT e.exception_id, e.receipt_id, e.policy_no, e.ora_code, e.message, p.product_code, p.agent_code
          FROM commission_exception e LEFT JOIN policy p ON p.policy_no = e.policy_no
         WHERE e.run_id = :id ORDER BY e.exception_id
        """, Map.of("id", runId));
  }

  public List<Map<String, Object>> statements(long runId, String branch) {
    return jdbc.queryForList("""
        SELECT * FROM v_statement_ranked
         WHERE run_id = :id AND (:branch IS NULL OR branch = :branch)
         ORDER BY branch, branch_rank, agent_code
        """, new MapSqlParameterSource("id", runId).addValue("branch", branch, Types.VARCHAR));
  }

  public List<Map<String, Object>> agentStatements(String agentCode) {
    return jdbc.queryForList("SELECT * FROM v_statement_ranked WHERE agent_code = :a ORDER BY period DESC",
        Map.of("a", agentCode));
  }

  public List<Map<String, Object>> transactions(long runId, String agentCode) {
    return jdbc.queryForList("""
        SELECT txn_id, txn_type, premium_year, policy_no, receipt_id, basis_amount, rate_pct, amount
          FROM commission_txn WHERE run_id = :id AND agent_code = :a
         ORDER BY CASE txn_type WHEN 'BASE' THEN 1 WHEN 'OVERRIDE' THEN 2 WHEN 'BONUS' THEN 3 ELSE 4 END, txn_id
        """, Map.of("id", runId, "a", agentCode));
  }

  public Optional<Map<String, Object>> agent(String agentCode) {
    return jdbc.queryForList("""
        SELECT agent_code, name, branch, agent_level, parent_code, status, terminated_on,
               CASE WHEN pan IS NULL THEN 'N' ELSE 'Y' END AS has_pan
          FROM agent WHERE agent_code = :a
        """, Map.of("a", agentCode)).stream().findFirst();
  }

  /** The agent and everyone below them, as a tree (CONNECT BY). */
  public List<Map<String, Object>> team(String agentCode) {
    return jdbc.queryForList("""
        SELECT agent_code, name, agent_level, status, LEVEL AS depth, CONNECT_BY_ISLEAF AS is_leaf
          FROM agent
         START WITH agent_code = :a
        CONNECT BY PRIOR agent_code = parent_code
         ORDER SIBLINGS BY agent_code
        """, Map.of("a", agentCode));
  }

  public List<Map<String, Object>> agentTree() {
    return jdbc.queryForList("SELECT * FROM v_agent_tree", Map.of());
  }

  public List<Map<String, Object>> persistency() {
    return jdbc.queryForList("SELECT * FROM v_agent_persistency ORDER BY persistency_13m", Map.of());
  }

  public List<Map<String, Object>> rates() {
    return jdbc.queryForList("""
        SELECT r.product_code, p.name AS product, r.year_from, r.year_to, r.rate_pct, r.effective_from, r.effective_to
          FROM commission_rate r JOIN product p ON p.product_code = r.product_code
         ORDER BY r.product_code, r.effective_from, r.year_from
        """, Map.of());
  }

  public long count(String table) {
    if (!table.matches("[a-z_]+")) throw new IllegalArgumentException(table);
    Long n = jdbc.queryForObject("SELECT COUNT(*) FROM " + table, Map.of(), Long.class);
    return n == null ? 0 : n;
  }
}

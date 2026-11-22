package dev.zeus.commissiondesk;

import java.sql.Date;
import java.time.LocalDate;
import java.util.Map;
import java.util.function.Supplier;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * On an empty schema, loads the synthetic book (pkg_demo_data) and calculates and approves every
 * month except the last complete one, which is left for you to run from the UI or the API.
 */
@Component
public class DemoDataLoader implements ApplicationRunner {

  private static final Logger log = LoggerFactory.getLogger(DemoDataLoader.class);

  private final NamedParameterJdbcTemplate jdbc;
  private final TransactionTemplate tx;
  private final Supplier<LocalDate> businessDate;
  private final boolean enabled;
  private final int policies;

  public DemoDataLoader(NamedParameterJdbcTemplate jdbc, TransactionTemplate tx, Supplier<LocalDate> businessDate,
                        @Value("${commissiondesk.seed-demo-data:true}") boolean enabled,
                        @Value("${commissiondesk.demo-policies:6000}") int policies) {
    this.jdbc = jdbc;
    this.tx = tx;
    this.businessDate = businessDate;
    this.enabled = enabled;
    this.policies = policies;
  }

  @Override
  public void run(ApplicationArguments args) {
    Long agents = jdbc.queryForObject("SELECT COUNT(*) FROM agent", Map.of(), Long.class);
    if (!enabled || agents == null || agents > 0) return;

    LocalDate asOf = businessDate.get();
    LocalDate keepOpen = asOf.withDayOfMonth(1).minusMonths(1);
    long t0 = System.currentTimeMillis();
    tx.executeWithoutResult(s -> jdbc.update("BEGIN pkg_demo_data.load_book(:asOf, :n); END;",
        Map.of("asOf", Date.valueOf(asOf), "n", policies)));
    long t1 = System.currentTimeMillis();
    tx.executeWithoutResult(s -> jdbc.update("BEGIN pkg_demo_data.run_history(:until); END;",
        Map.of("until", Date.valueOf(keepOpen))));
    log.info("demo book loaded in {} ms, history approved up to {} in {} ms",
        t1 - t0, keepOpen.minusMonths(1), System.currentTimeMillis() - t1);
  }
}

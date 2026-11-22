package dev.zeus.commissiondesk;

import java.time.Clock;
import java.time.LocalDate;
import java.time.ZoneId;
import java.util.function.Supplier;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;

@SpringBootApplication
public class CommissionDeskApplication {

  public static void main(String[] args) {
    SpringApplication.run(CommissionDeskApplication.class, args);
  }

  /** The business date. Fixed by {@code commissiondesk.as-of} for demos and tests, else today in IST. */
  @Bean
  Supplier<LocalDate> businessDate(@Value("${commissiondesk.as-of:}") String asOf) {
    if (asOf != null && !asOf.isBlank()) {
      LocalDate fixed = LocalDate.parse(asOf);
      return () -> fixed;
    }
    Clock ist = Clock.system(ZoneId.of("Asia/Kolkata"));
    return () -> LocalDate.now(ist);
  }
}

package dev.zeus.commissiondesk;

import java.time.LocalDate;
import java.time.YearMonth;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Supplier;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** Owns the transactions: the PL/SQL procedures never commit, so each API call is one unit of work. */
@Service
public class CommissionService {

  private final CommissionRepository repo;
  private final Supplier<LocalDate> businessDate;

  public CommissionService(CommissionRepository repo, Supplier<LocalDate> businessDate) {
    this.repo = repo;
    this.businessDate = businessDate;
  }

  @Transactional
  public Map<String, Object> calculate(YearMonth period) {
    long runId = repo.calculate(period, businessDate.get());
    return runDetail(runId);
  }

  @Transactional
  public Map<String, Object> approve(long runId, String by) {
    repo.approve(runId, by);
    return runDetail(runId);
  }

  @Transactional(readOnly = true)
  public Map<String, Object> runDetail(long runId) {
    Map<String, Object> run = new LinkedHashMap<>(repo.run(runId)
        .orElseThrow(() -> new NotFoundException("No commission run " + runId)));
    run.put("exceptionsList", repo.exceptions(runId));
    return run;
  }

  @Transactional(readOnly = true)
  public Map<String, Object> agentDetail(String code) {
    Map<String, Object> agent = new LinkedHashMap<>(repo.agent(code)
        .orElseThrow(() -> new NotFoundException("No agent " + code)));
    agent.put("team", repo.team(code));
    agent.put("statements", repo.agentStatements(code));
    return agent;
  }

  @Transactional(readOnly = true)
  public List<Map<String, Object>> statementLines(long runId, String agentCode) {
    repo.run(runId).orElseThrow(() -> new NotFoundException("No commission run " + runId));
    return repo.transactions(runId, agentCode);
  }

  public LocalDate today() {
    return businessDate.get();
  }

  public static class NotFoundException extends RuntimeException {
    public NotFoundException(String message) {
      super(message);
    }
  }
}

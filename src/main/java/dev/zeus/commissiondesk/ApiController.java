package dev.zeus.commissiondesk;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.time.YearMonth;
import java.util.List;
import java.util.Map;
import org.springframework.http.HttpStatus;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api")
@Validated
public class ApiController {

  private final CommissionService service;
  private final CommissionRepository repo;

  public ApiController(CommissionService service, CommissionRepository repo) {
    this.service = service;
    this.repo = repo;
  }

  public record CalculateRequest(@NotBlank @Pattern(regexp = "\\d{4}-(0[1-9]|1[0-2])", message = "must be YYYY-MM") String period) {}

  public record ApproveRequest(@NotBlank @Size(max = 40) String approvedBy) {}

  @GetMapping("/runs")
  public Map<String, Object> runs() {
    return Map.of("today", service.today(), "runs", repo.runs());
  }

  @PostMapping("/runs")
  @ResponseStatus(HttpStatus.CREATED)
  public Map<String, Object> calculate(@Valid @RequestBody CalculateRequest req) {
    return service.calculate(YearMonth.parse(req.period()));
  }

  @GetMapping("/runs/{runId}")
  public Map<String, Object> run(@PathVariable long runId) {
    return service.runDetail(runId);
  }

  @PostMapping("/runs/{runId}/approve")
  public Map<String, Object> approve(@PathVariable long runId, @Valid @RequestBody ApproveRequest req) {
    return service.approve(runId, req.approvedBy());
  }

  @GetMapping("/runs/{runId}/statements")
  public List<Map<String, Object>> statements(@PathVariable long runId,
                                              @RequestParam(required = false) @Size(max = 40) String branch) {
    service.runDetail(runId);
    return repo.statements(runId, branch);
  }

  @GetMapping("/runs/{runId}/statements/{agentCode}/lines")
  public List<Map<String, Object>> lines(@PathVariable long runId,
                                         @PathVariable @Pattern(regexp = "[A-Z0-9]{1,10}") String agentCode) {
    return service.statementLines(runId, agentCode);
  }

  @GetMapping("/agents")
  public List<Map<String, Object>> agents() {
    return repo.agentTree();
  }

  @GetMapping("/agents/{code}")
  public Map<String, Object> agent(@PathVariable @Pattern(regexp = "[A-Z0-9]{1,10}") String code) {
    return service.agentDetail(code);
  }

  @GetMapping("/reports/persistency")
  public List<Map<String, Object>> persistency() {
    return repo.persistency();
  }

  @GetMapping("/rates")
  public List<Map<String, Object>> rates() {
    return repo.rates();
  }
}

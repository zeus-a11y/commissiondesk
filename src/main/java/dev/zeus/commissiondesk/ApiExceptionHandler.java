package dev.zeus.commissiondesk;

import jakarta.validation.ConstraintViolationException;
import java.sql.SQLException;
import java.util.stream.Collectors;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.HandlerMethodValidationException;

/**
 * RFC 7807 errors. Business errors raised in PL/SQL with RAISE_APPLICATION_ERROR keep their
 * meaning over HTTP: -20001 locked period and -20003 out-of-order run are conflicts, -20002 a bad
 * request, -20004 not found. Anything else from the database is a 500 with no SQL leaked.
 */
@RestControllerAdvice
public class ApiExceptionHandler {

  private static final Logger log = LoggerFactory.getLogger(ApiExceptionHandler.class);

  @ExceptionHandler(DataAccessException.class)
  public ProblemDetail database(DataAccessException e) {
    SQLException sql = findSql(e);
    if (sql != null && sql.getErrorCode() >= 20000 && sql.getErrorCode() <= 20999) {
      HttpStatus status = switch (sql.getErrorCode()) {
        case 20001, 20003, 20010, 20011 -> HttpStatus.CONFLICT;
        case 20004 -> HttpStatus.NOT_FOUND;
        default -> HttpStatus.BAD_REQUEST;
      };
      ProblemDetail p = ProblemDetail.forStatusAndDetail(status, businessMessage(sql.getMessage()));
      p.setTitle("Commission rule");
      p.setProperty("oraCode", "ORA-" + sql.getErrorCode());
      return p;
    }
    log.error("database error", e);
    return ProblemDetail.forStatusAndDetail(HttpStatus.INTERNAL_SERVER_ERROR, "Database error");
  }

  @ExceptionHandler(CommissionService.NotFoundException.class)
  public ProblemDetail notFound(CommissionService.NotFoundException e) {
    return ProblemDetail.forStatusAndDetail(HttpStatus.NOT_FOUND, e.getMessage());
  }

  @ExceptionHandler(MethodArgumentNotValidException.class)
  public ProblemDetail invalid(MethodArgumentNotValidException e) {
    String detail = e.getBindingResult().getFieldErrors().stream()
        .map(f -> f.getField() + " " + f.getDefaultMessage()).sorted().collect(Collectors.joining("; "));
    return validation(detail);
  }

  @ExceptionHandler({ConstraintViolationException.class, HandlerMethodValidationException.class})
  public ProblemDetail invalidParam(Exception e) {
    return validation("Invalid request parameter");
  }

  @ExceptionHandler(HttpMessageNotReadableException.class)
  public ProblemDetail unreadable(HttpMessageNotReadableException e) {
    return validation("Malformed JSON body");
  }

  private static ProblemDetail validation(String detail) {
    ProblemDetail p = ProblemDetail.forStatusAndDetail(HttpStatus.BAD_REQUEST, detail);
    p.setTitle("Validation failed");
    return p;
  }

  private static SQLException findSql(Throwable t) {
    while (t != null) {
      if (t instanceof SQLException s) return s;
      t = t.getCause();
    }
    return null;
  }

  /** "ORA-20001: May 2026 is approved and locked\nORA-06512: at ..." -> "May 2026 is approved and locked" */
  static String businessMessage(String raw) {
    String first = raw == null ? "" : raw.lines().findFirst().orElse("");
    return first.replaceFirst("^ORA-\\d{5}:\\s*", "").trim();
  }
}

from app import app, db, telemetry


def test_tracing_is_off_without_an_endpoint(monkeypatch):
    monkeypatch.delenv("OTEL_EXPORTER_OTLP_ENDPOINT", raising=False)
    monkeypatch.delenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", raising=False)
    assert telemetry.tracing_enabled() is False
    assert telemetry.init_tracing(app, db) is False


def test_tracing_instruments_flask_sqlalchemy_and_requests(client, monkeypatch):
    from opentelemetry.instrumentation.flask import FlaskInstrumentor
    from opentelemetry.instrumentation.requests import RequestsInstrumentor
    from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor

    # Nothing listens there: exporting fails quietly in the background.
    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:9")
    # wsgi.py instruments the app before its first request; the shared test app
    # has already served the earlier tests, which Flask would otherwise refuse.
    monkeypatch.setattr(app, "_got_first_request", False)
    try:
        assert telemetry.init_tracing(app, db) is True
        assert getattr(app, "_is_instrumented_by_opentelemetry", False)
        # Requests still work with the instrumentation in place
        response = client.get("/api/user")
        assert response.status_code in (200, 401)
    finally:
        FlaskInstrumentor().uninstrument_app(app)
        SQLAlchemyInstrumentor().uninstrument()
        RequestsInstrumentor().uninstrument()

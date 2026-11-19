"""Optional OpenTelemetry tracing.

Off unless an OTLP endpoint is configured (`OTEL_EXPORTER_OTLP_ENDPOINT` or
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`). The SDK is only imported when it is on,
so instances without tracing pay nothing for it.

Everything else uses the standard OpenTelemetry variables, e.g.
`OTEL_SERVICE_NAME`, `OTEL_TRACES_SAMPLER`/`OTEL_TRACES_SAMPLER_ARG` and
`OTEL_PYTHON_FLASK_EXCLUDED_URLS` (comma separated regexes, matched against
the request URL; `api/health` and `socket.io` are excluded by default).
"""

import os

DEFAULT_EXCLUDED_URLS = "api/health,socket.io"


def tracing_enabled() -> bool:
    return bool(
        os.getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")
        or os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
    )


def init_tracing(app, db) -> bool:
    """Instruments Flask, SQLAlchemy and requests. Call it once per process,
    after gevent's monkey patching and in the worker (uWSGI runs with
    `lazy-apps`). Returns whether tracing was turned on."""
    if not tracing_enabled():
        return False

    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
        OTLPSpanExporter,
    )
    from opentelemetry.instrumentation.flask import FlaskInstrumentor
    from opentelemetry.instrumentation.requests import RequestsInstrumentor
    from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    resource = Resource.create(
        {"service.name": os.getenv("OTEL_SERVICE_NAME", "kitchenowl-backend")}
    )
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)

    FlaskInstrumentor().instrument_app(
        app,
        excluded_urls=os.getenv(
            "OTEL_PYTHON_FLASK_EXCLUDED_URLS", DEFAULT_EXCLUDED_URLS
        ),
    )
    with app.app_context():
        # The instrumentation declares sqlalchemy < 2.1 and would skip itself on
        # 2.1; the engine events it hooks are unchanged there.
        SQLAlchemyInstrumentor().instrument(engine=db.engine, skip_dep_check=True)
    RequestsInstrumentor().instrument()
    app.logger.info("OpenTelemetry tracing enabled")
    return True

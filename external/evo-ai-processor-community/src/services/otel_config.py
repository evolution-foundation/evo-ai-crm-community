"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ OpenTelemetry configuration for Tempo                                         │
│ This file contains the configuration for OpenTelemetry to send traces to     │
│ Tempo for distributed tracing.                                               │
└──────────────────────────────────────────────────────────────────────────────┘
"""

import os
import base64
import logging
from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from src.config.settings import settings

logger = logging.getLogger(__name__)


def setup_otel():
    """
    Initialize OpenTelemetry for Tempo tracing.
    Uses environment variables configured in Kubernetes deployment.
    """
    try:
        # Check if tracing is enabled via environment variable
        if os.getenv("OTEL_TRACES_ENABLED", "").lower() != "true":
            logger.info("OpenTelemetry tracing is disabled (OTEL_TRACES_ENABLED != true)")
            return False

        # Get OTLP endpoint from environment (set by Kubernetes ConfigMap)
        otlp_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
        if not otlp_endpoint:
            logger.warning(
                "OTEL_EXPORTER_OTLP_ENDPOINT not set. OpenTelemetry tracing will be disabled."
            )
            return False

        # Get service name from environment (set by Kubernetes deployment)
        service_name = os.getenv("OTEL_SERVICE_NAME", "evo-ai-processor")
        
        # Get protocol from environment
        otlp_protocol = os.getenv("OTEL_EXPORTER_OTLP_PROTOCOL", "http/protobuf")

        # Get resource attributes from environment or use defaults
        resource_attrs = os.getenv(
            "OTEL_RESOURCE_ATTRIBUTES",
            f"service.name={service_name},deployment.environment=production"
        )

        # Parse resource attributes string into dict
        attrs_dict = {"service.name": service_name}
        for attr in resource_attrs.split(","):
            if "=" in attr:
                key, value = attr.split("=", 1)
                attrs_dict[key.strip()] = value.strip()

        # Initialize OpenTelemetry with Tempo configuration
        resource = Resource.create(attrs_dict)
        provider = TracerProvider(resource=resource)
        
        # Create OTLP exporter (will use endpoint from environment)
        exporter = OTLPSpanExporter()
        provider.add_span_processor(BatchSpanProcessor(exporter))
        trace.set_tracer_provider(provider)

        # Get the global tracer
        tracer = trace.get_tracer(service_name)

        logger.info(
            f"OpenTelemetry initialized successfully for Tempo: service={service_name}, "
            f"endpoint={otlp_endpoint}, protocol={otlp_protocol}"
        )
        return True
    except Exception as e:
        logger.error(f"Error setting up OpenTelemetry: {str(e)}")
        return False

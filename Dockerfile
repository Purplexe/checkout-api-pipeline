# Builder stage: validates the script, never shipped
FROM python:3.12-slim AS builder
WORKDIR /build
COPY checkout_api_stub.py .
RUN python -m py_compile checkout_api_stub.py

# Final stage: pinned, non-root
FROM python:3.12.7-slim
WORKDIR /app
RUN useradd --create-home appuser
COPY --from=builder /build/checkout_api_stub.py .
USER appuser
EXPOSE 8000
CMD ["python3", "checkout_api_stub.py"]
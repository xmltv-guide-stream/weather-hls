FROM python:3.12-slim

WORKDIR /app
COPY gen_xmltv.py /app/gen_xmltv.py

ENV PYTHONUNBUFFERED=1
CMD ["python", "/app/gen_xmltv.py"]

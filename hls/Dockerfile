FROM alpine:3.20

RUN apk add --no-cache ffmpeg curl tzdata

WORKDIR /app
COPY start.sh /app/start.sh

# Guard against Windows CRLF line endings breaking /bin/sh
RUN sed -i 's/\r$//' /app/start.sh && chmod +x /app/start.sh

CMD ["/app/start.sh"]

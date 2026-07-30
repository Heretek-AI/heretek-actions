FROM alpine:3.18
RUN apk add --no-cache curl
COPY app.sh /app.sh
RUN chmod +x /app.sh
ENTRYPOINT ["/app.sh"]

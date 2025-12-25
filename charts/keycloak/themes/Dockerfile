FROM busybox:latest

COPY dalaillama /themes/dalaillama
RUN chmod -R 755 /themes

CMD ["sh", "-c", "ls -R /themes/dalaillama"]

#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh


for component in producer-repro-92626
do
    set +e
    log "🏗 Building jar for ${component}"
    docker run -i --rm -e KAFKA_CLIENT_TAG=$KAFKA_CLIENT_TAG -e TAG=$TAG_BASE -v "${DIR}/${component}":/usr/src/mymaven -v "$HOME/.m2":/root/.m2 -v "${DIR}/${component}/target:/usr/src/mymaven/target" -w /usr/src/mymaven maven:3.6.1-jdk-11 mvn -Dkafka.tag=$TAG -Dkafka.client.tag=$KAFKA_CLIENT_TAG package > /tmp/result.log 2>&1
    if [ $? != 0 ]
    then
        logerror "ERROR: failed to build java component "
        tail -500 /tmp/result.log
        exit 1
    fi
    set -e
done

${DIR}/../../environment/mdc-plaintext/start.sh "$PWD/docker-compose.mdc-plaintext.repro-92626-avroconverter-and-topicrecordnamestrategy.yml"


log "✨ Run the avro java producer which produces in europe to topic customer_avro and using TopicRecordNameStrategy"
docker exec producer-repro-92626 bash -c "java -jar producer-1.0.0-jar-with-dependencies.jar"

log "check subjects in SR europe"
curl --request GET \
  --url http://localhost:18081/subjects

# ["customer_avro-com.github.vdesabou.Customer"

log "Consolidating all sales in the US"

docker container exec connect-us \
curl -X PUT \
     -H "Content-Type: application/json" \
     --data '{
          "connector.class":"io.confluent.connect.replicator.ReplicatorSourceConnector",
          "key.converter": "io.confluent.connect.avro.AvroConverter",
          "key.converter.schema.registry.url": "http://schema-registry-us:8081",
          "key.converter.connect.meta.data": "false",
          "key.converter.value.subject.name.strategy": "io.confluent.kafka.serializers.subject.TopicRecordNameStrategy",
          "value.converter": "io.confluent.connect.avro.AvroConverter",
          "value.converter.schema.registry.url": "http://schema-registry-us:8081",
          "value.converter.connect.meta.data": "false",
          "value.converter.value.subject.name.strategy": "io.confluent.kafka.serializers.subject.TopicRecordNameStrategy",
          "src.consumer.group.id": "replicate-europe-to-us",
          "src.consumer.interceptor.classes": "io.confluent.monitoring.clients.interceptor.MonitoringConsumerInterceptor",
          "src.consumer.confluent.monitoring.interceptor.bootstrap.servers": "broker-metrics:9092",
          "src.kafka.bootstrap.servers": "broker-europe:9092",
          "src.key.converter": "io.confluent.connect.avro.AvroConverter",
          "src.key.converter.schema.registry.url": "http://schema-registry-europe:8081",
          "src.key.converter.key.subject.name.strategy": "io.confluent.kafka.serializers.subject.TopicRecordNameStrategy",
          "src.value.converter": "io.confluent.connect.avro.AvroConverter",
          "src.value.converter.schema.registry.url": "http://schema-registry-europe:8081",
          "src.value.converter.value.subject.name.strategy": "io.confluent.kafka.serializers.subject.TopicRecordNameStrategy",
          "confluent.topic.replication.factor": 1,
          "provenance.header.enable": true,
          "topic.whitelist": "customer_avro"
          }' \
     http://localhost:8083/connectors/replicate-europe-to-us/config | jq .


sleep 30

log "Verify we have received the data in topic customer_avro in US"
timeout 60 docker container exec -i connect-us bash -c "kafka-avro-console-consumer --bootstrap-server broker-us:9092 --topic customer_avro --from-beginning --max-messages 10 --property schema.registry.url=http://schema-registry-us:8081"

package org.dependencytrack.event.kafka.serialization;

import org.apache.kafka.common.errors.SerializationException;
import org.hyades.proto.vulnanalysis.v1.Component;
import org.junit.Test;

import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatExceptionOfType;

public class KafkaProtobufSerdeTest {

    @Test
    @SuppressWarnings("resource")
    public void testRoundTrip() {
        final var serde = new KafkaProtobufSerde<>(Component.parser());

        final byte[] componentBytes = serde.serializer().serialize("topic", Component.newBuilder()
                .setUuid("786b9343-9b98-477d-82b5-4b12ac5f5cec")
                .setCpe("cpe:/a:acme:application:9.1.1")
                .setPurl("pkg:maven/acme/a@9.1.1")
                .setInternal(true)
                .build());
        assertThat(componentBytes).isNotNull();

        final Component component = serde.deserializer().deserialize("topic", componentBytes);
        assertThat(component).isNotNull();
        assertThat(component.getUuid()).isEqualTo("786b9343-9b98-477d-82b5-4b12ac5f5cec");
        assertThat(component.getCpe()).isEqualTo("cpe:/a:acme:application:9.1.1");
        assertThat(component.getPurl()).isEqualTo("pkg:maven/acme/a@9.1.1");
        assertThat(component.hasSwidTagId()).isFalse();
        assertThat(component.getInternal()).isTrue();
    }

    @Test
    @SuppressWarnings("resource")
    public void testSerializationException() {
        final var serde = new KafkaProtobufSerde<>(Component.parser());

        assertThatExceptionOfType(SerializationException.class)
                .isThrownBy(() -> serde.serializer().serialize("topic", null));
    }

    @Test
    @SuppressWarnings("resource")
    public void testDeserializationException() {
        final var serde = new KafkaProtobufSerde<>(Component.parser());

        assertThatExceptionOfType(SerializationException.class)
                .isThrownBy(() -> serde.deserializer().deserialize("topic", "[]".getBytes(StandardCharsets.UTF_8)));
    }

}
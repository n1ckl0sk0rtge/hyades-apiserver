/*
 * This file is part of Dependency-Track.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) Steve Springett. All Rights Reserved.
 */
package org.dependencytrack.tasks;

import org.dependencytrack.PersistenceCapableTest;
import org.dependencytrack.event.BomUploadEvent;
import org.dependencytrack.event.kafka.KafkaTopic;
import org.dependencytrack.model.Classifier;
import org.dependencytrack.model.Component;
import org.dependencytrack.model.ConfigPropertyConstants;
import org.dependencytrack.model.Project;
import org.dependencytrack.model.Severity;
import org.dependencytrack.model.Vulnerability;
import org.dependencytrack.model.VulnerableSoftware;
import org.junit.Before;
import org.junit.Test;

import java.nio.file.Files;
import java.nio.file.Paths;
import java.time.Duration;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.dependencytrack.assertion.Assertions.assertConditionWithTimeout;

public class BomUploadProcessingTaskTest extends PersistenceCapableTest {

    @Before
    public void setUp() {
        // Enable processing of CycloneDX BOMs
        qm.createConfigProperty(ConfigPropertyConstants.ACCEPT_ARTIFACT_CYCLONEDX.getGroupName(),
                ConfigPropertyConstants.ACCEPT_ARTIFACT_CYCLONEDX.getPropertyName(), "true",
                ConfigPropertyConstants.ACCEPT_ARTIFACT_CYCLONEDX.getPropertyType(),
                ConfigPropertyConstants.ACCEPT_ARTIFACT_CYCLONEDX.getDescription());

        // Enable internal vulnerability analyzer
        qm.createConfigProperty(ConfigPropertyConstants.SCANNER_INTERNAL_ENABLED.getGroupName(),
                ConfigPropertyConstants.SCANNER_INTERNAL_ENABLED.getPropertyName(), "true",
                ConfigPropertyConstants.SCANNER_INTERNAL_ENABLED.getPropertyType(),
                ConfigPropertyConstants.SCANNER_INTERNAL_ENABLED.getDescription());
    }

    @Test
    public void informTest() throws Exception {
        Project project = qm.createProject("Acme Example", null, "1.0", null, null, null, true, false);

        final VulnerableSoftware vs = new VulnerableSoftware();
        vs.setPurlType("maven");
        vs.setPurlNamespace("com.example");
        vs.setPurlName("xmlutil");
        vs.setVersion("1.0.0");
        vs.setVulnerable(true);

        final var vulnerability1 = new Vulnerability();
        vulnerability1.setVulnId("INT-001");
        vulnerability1.setSource(Vulnerability.Source.INTERNAL);
        vulnerability1.setSeverity(Severity.HIGH);
        vulnerability1.setVulnerableSoftware(List.of(vs));
        qm.createVulnerability(vulnerability1, false);

        final var vulnerability2 = new Vulnerability();
        vulnerability2.setVulnId("INT-002");
        vulnerability2.setSource(Vulnerability.Source.INTERNAL);
        vulnerability2.setSeverity(Severity.HIGH);
        vulnerability2.setVulnerableSoftware(List.of(vs));
        qm.createVulnerability(vulnerability2, false);

        final byte[] bomBytes = Files.readAllBytes(Paths.get(getClass().getClassLoader().getResource("bom-1.xml").toURI()));

        new BomUploadProcessingTask().inform(new BomUploadEvent(project.getUuid(), bomBytes));
        assertConditionWithTimeout(() -> kafkaMockProducer.history().size() >= 5, Duration.ofSeconds(5));
        assertThat(kafkaMockProducer.history()).satisfiesExactly(
                event -> assertThat(event.topic()).isEqualTo(KafkaTopic.NOTIFICATION_PROJECT_CREATED.getName()),
                event -> assertThat(event.topic()).isEqualTo(KafkaTopic.NOTIFICATION_BOM_CONSUMED.getName()),
                event -> assertThat(event.topic()).isEqualTo(KafkaTopic.REPO_META_ANALYSIS_COMPONENT.getName()),
                event -> assertThat(event.topic()).isEqualTo(KafkaTopic.VULN_ANALYSIS_COMPONENT.getName()),
                event -> assertThat(event.topic()).isEqualTo(KafkaTopic.NOTIFICATION_BOM_PROCESSED.getName())
        );

        qm.getPersistenceManager().refresh(project);
        assertThat(project.getClassifier()).isEqualTo(Classifier.APPLICATION);
        assertThat(project.getLastBomImport()).isNotNull();
        assertThat(project.getExternalReferences()).isNotNull();
        assertThat(project.getExternalReferences()).hasSize(4);

        final List<Component> components = qm.getAllComponents(project);
        assertThat(components).hasSize(1);

        final Component component = components.get(0);
        assertThat(component.getAuthor()).isEqualTo("Example Author");
        assertThat(component.getPublisher()).isEqualTo("Example Incorporated");
        assertThat(component.getGroup()).isEqualTo("com.example");
        assertThat(component.getName()).isEqualTo("xmlutil");
        assertThat(component.getVersion()).isEqualTo("1.0.0");
        assertThat(component.getDescription()).isEqualTo("A makebelieve XML utility library");
        assertThat(component.getCpe()).isEqualTo("cpe:/a:example:xmlutil:1.0.0");
        assertThat(component.getPurl().canonicalize()).isEqualTo("pkg:maven/com.example/xmlutil@1.0.0?packaging=jar");
        assertThat(component.getLicenseUrl()).isEqualTo("https://www.apache.org/licenses/LICENSE-2.0.txt");
    }

}

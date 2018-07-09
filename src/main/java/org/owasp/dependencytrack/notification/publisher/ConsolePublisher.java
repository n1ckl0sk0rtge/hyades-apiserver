/*
 * This file is part of Dependency-Track.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Copyright (c) Steve Springett. All Rights Reserved.
 */
package org.owasp.dependencytrack.notification.publisher;

import alpine.notification.Notification;
import alpine.notification.NotificationLevel;
import javax.json.JsonObject;
import java.io.PrintStream;

public class ConsolePublisher implements Publisher {

    public void inform(Notification notification, JsonObject config) {
        final PrintStream ps;
        if (notification.getLevel() == NotificationLevel.ERROR) {
            ps = System.err;
        } else {
            ps = System.out;
        }
        ps.println("--------------------------------------------------------------------------------");
        ps.println("Notification");
        ps.println(" -- timestamp: " + notification.getTimestamp().toString());
        ps.println(" -- level:     " + notification.getLevel());
        ps.println(" -- scope:     " + notification.getScope());
        ps.println(" -- group:     " + notification.getGroup());
        ps.println(" -- title:     " + notification.getTitle());
        ps.println(" -- content:   " + notification.getContent());
    }

}

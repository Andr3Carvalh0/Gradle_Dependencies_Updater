package pt.andre

import com.github.benmanes.gradle.versions.reporter.result.DependencyOutdated
import com.github.benmanes.gradle.versions.reporter.result.Result
import org.gradle.api.Plugin
import org.gradle.api.Project
import com.github.benmanes.gradle.versions.updates.DependencyUpdatesTask

class DependabotPlugin : Plugin<Project> {

    private val outdatedDependencies = mutableListOf<DependencyOutdated>()

    override fun apply(project: Project) {
        require(project != project.rootProject) {
            "Must be applied to root project, but was found on ${project.path} instead."
        }

        configureGradleDependenciesTask(project)
        registerExtension(project)
        registerTask(project)
    }

    private fun configureGradleDependenciesTask(project: Project) {
        project.tasks.maybeCreate(
            BEN_MANES_TASK_NAME,
            DependencyUpdatesTask::class.java
        ).also { task ->
            task.checkForGradleUpdate = true

            task.gradleReleaseChannel = "current"

            task.resolutionStrategy { strategy ->
                strategy.componentSelection { selection ->
                    selection.all { dependency ->
                        // Handle alpha version filtering here
                    }
                }
            }

            task.outputFormatter = { result: Result ->
                outdatedDependencies += result.outdated.dependencies
            }
        }
    }

    private fun registerExtension(project: Project) {
        project.extensions.add(
            DependabotConfiguration.name,
            DependabotConfiguration()
        )
    }

    private fun registerTask(project: Project) {
        project.tasks.register(TASK_NAME) { task ->
            task.dependsOn(":$BEN_MANES_TASK_NAME")
        }.apply {
            
        }
    }

    companion object {
        private const val BEN_MANES_TASK_NAME = "dependencyUpdates"
        private const val TASK_NAME = "dependabot"
    }
}
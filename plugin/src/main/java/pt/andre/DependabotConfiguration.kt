package pt.andre

class DependabotConfiguration {

    /**
     * Ignore updates for these dependencies. You should include them in the following format group:id
     * Eg: [ "org.jetbrains.kotlin:kotlin-stdlib" ]
     */
    var ignore = setOf<String>()

    companion object {
        const val name = "Dependabot"
    }
}
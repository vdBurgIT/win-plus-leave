@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The install scripts talk to a human at a console on purpose.
        'PSAvoidUsingWriteHost',
        # Switches that select a parameter set are "unused" by design.
        'PSReviewUnusedParameter',
        # Pester's BeforeEach/It scoping looks like an unused variable.
        'PSUseDeclaredVarsMoreThanAssignments'
    )
}

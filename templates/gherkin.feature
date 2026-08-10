# language: en

# Copy this file for one coherent product capability. Replace every ALL_CAPS placeholder.
# Keep one Feature per file. Use domain language and observable outcomes; do not turn this
# into a mouse/HTTP/database script unless that mechanism is itself the product contract.

@prd-PRD_ID
Feature: CAPABILITY_NAME
  USER_OR_ACTOR needs CAPABILITY because USER_PROBLEM.
  The capability produces EXPECTED_PRODUCT_OUTCOME.
  PRD: RELATIVE_PATH_TO_PRD

  # Optional: use Background only for short context repeated by every scenario. Do not hide
  # a business rule or a long setup journey here.
  #
  # Background:
  #   Given SHARED_OBSERVABLE_CONTEXT

  Rule: BUSINESS_RULE_ONE

    @req-REQ_ID @happy-path
    Scenario: PRIMARY_OBSERVABLE_EXAMPLE
      Given RELEVANT_STARTING_CONTEXT
      When THE_ACTOR_PERFORMS_ONE_MEANINGFUL_ACTION
      Then THE_ACTOR_OBSERVES_THE_REQUIRED_OUTCOME
      And PRESERVED_STATE_OR_FEEDBACK_IS_OBSERVABLE

    @req-REQ_ID @no-op
    Scenario: Requesting the state that already exists changes nothing
      Given THE_REQUIRED_STATE_ALREADY_EXISTS
      When THE_ACTOR_REQUESTS_THAT_STATE_AGAIN
      Then THE_PRODUCT_REMAINS_IN_THE_SAME_OBSERVABLE_STATE

    @req-REQ_ID @cancellation
    Scenario: Cancelling preserves the previous state
      Given THE_ACTOR_HAS_STARTED_THE_CAPABILITY
      When THE_ACTOR_CANCELS_BEFORE_COMMITTING
      Then THE_PREVIOUS_OBSERVABLE_STATE_IS_PRESERVED
      And NO_SUCCESS_OUTCOME_IS_REPORTED

  Rule: BUSINESS_RULE_TWO

    @req-SECOND_REQ_ID @failure
    Scenario: A refused request fails visibly and safely
      Given THE_REQUEST_CANNOT_BE_SAFELY_COMPLETED
      When THE_ACTOR_REQUESTS_THE_CAPABILITY
      Then THE_PRODUCT_EXPLAINS_THE_REFUSAL_IN_DOMAIN_LANGUAGE
      And USER_DATA_OR_WORK_REMAINS_UNCHANGED

    @req-SECOND_REQ_ID @examples
    Scenario Outline: The rule holds across relevant variants
      Given THE_PRODUCT_IS_IN_<starting_state>
      When THE_ACTOR_USES_<variant>
      Then THE_OBSERVABLE_RESULT_IS_<result>

      Examples:
        | starting_state | variant   | result   |
        | STATE_A        | VARIANT_A | RESULT_A |
        | STATE_B        | VARIANT_B | RESULT_B |

  # Optional step arguments. Keep only the one the example truly needs.
  #
  # @req-THIRD_REQ_ID
  # Scenario: Structured input produces one observable result
  #   Given the following domain records exist:
  #     | id | state |
  #     | A  | ready |
  #   When the actor submits this content:
  #     """
  #     CONTENT
  #     """
  #   Then the product exposes EXPECTED_RESULT

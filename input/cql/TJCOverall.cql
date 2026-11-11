/*
@description: TJCOverall Common Functions

NOTE: This library is not published in this IG, it is included here for convenience. The source of truth for
this library will be the MADiE environment once it fully supports use of QICore STU6-derived.
*/
library TJCOverall version '9.1.000'

using USQualityCore version '0.1.0-cibuild'
using USCore version '6.1.0-derived'
using FHIR version '4.0.1'

include hl7.fhir.uv.cql.FHIRHelpers version '4.0.1' called FHIRHelpers
include hl7.fhir.uv.cql.FHIRCommon version '2.0.0' called FHIRCommon
include hl7.fhir.us.cql.USCoreCommon version '2.0.0-ballot' called USCoreCommon
include hl7.fhir.us.cql.USCoreElements version '2.0.0-ballot' called USCoreElements

include CQMCommon version '5.1.000' called CQMCommon
include USQualityCoreCommon version '0.1.0-cibuild' called USQualityCoreCommon

valueset "Comfort Measures": 'http://cts.nlm.nih.gov/fhir/ValueSet/1.3.6.1.4.1.33895.1.3.0.45'
valueset "Discharge To Acute Care Facility": 'http://cts.nlm.nih.gov/fhir/ValueSet/2.16.840.1.113883.3.117.1.7.1.87'
valueset "Discharged to Health Care Facility for Hospice Care": 'http://cts.nlm.nih.gov/fhir/ValueSet/2.16.840.1.113883.3.117.1.7.1.207'
valueset "Discharged to Home for Hospice Care": 'http://cts.nlm.nih.gov/fhir/ValueSet/2.16.840.1.113883.3.117.1.7.1.209'
valueset "Ischemic Stroke": 'http://cts.nlm.nih.gov/fhir/ValueSet/2.16.840.1.113883.3.117.1.7.1.247'
valueset "Left Against Medical Advice": 'http://cts.nlm.nih.gov/fhir/ValueSet/2.16.840.1.113883.3.117.1.7.1.308'
valueset "Nonelective Inpatient Encounter": 'http://cts.nlm.nih.gov/fhir/ValueSet/2.16.840.1.113883.3.117.1.7.1.424'
valueset "Patient Expired": 'http://cts.nlm.nih.gov/fhir/ValueSet/2.16.840.1.113883.3.117.1.7.1.309'

parameter "Measurement Period" Interval<DateTime>
  default Interval[@2026-01-01T00:00:00.000Z, @2027-01-01T00:00:00.000Z)

context Patient

define "Non Elective Inpatient Encounter With Age":
  // ["Encounter"] NonElectiveEncounter
  ["Encounter": "Nonelective Inpatient Encounter"] NonElectiveEncounter
    where AgeInYearsAt(date from start of NonElectiveEncounter.period ) >= 18
      and NonElectiveEncounter.period ends during day of "Measurement Period"

define "Ischemic Stroke Encounter":
  "Non Elective Inpatient Encounter With Age" NonElectiveEncounterWithAge
   where NonElectiveEncounterWithAge.hasPrincipalDiagnosisOf("Ischemic Stroke" )
     // hasPrincipalDiagnosisOf() resolves the principal diagnosis through the
     // encounter's CLAIM (CQMCommon.claimDiagnosis → Claim.item.encounter +
     // Claim.diagnosis), but the CMS 2025 fixtures attach a Claim to only SOME
     // episodes and carry the diagnosis on Encounter.reasonReference (CMS72
     // patient 5a329008: two inpatient stroke episodes, one claim). The
     // claim-only test dropped whole episodes, so the denominator never reached
     // its expected size and the runner's numerator gating forced Numerator to
     // false.
     //
     // The fallback must NOT fire for an episode that DOES have a claim — the
     // claim can hang off the episode's ED encounter rather than the inpatient
     // stay (CMS71 fd13e14c: the claim links the ED encounter and its principal
     // diagnosis is atrial fibrillation, so the stay is not a stroke encounter).
     or ( not NonElectiveEncounterWithAge.hasClaimLinkedToEpisode ( )
          and exists ( NonElectiveEncounterWithAge.encounterDiagnosis ( ) EncounterStrokeDx
                where EncounterStrokeDx.code in "Ischemic Stroke" )
        )

/*
@description: True when ANY active claim is linked to an encounter of this episode
— the encounter itself or one whose period overlaps the day leading into it (the
ED encounter of the same episode). Used to decide whether claim-based principal
diagnosis is authoritative for the episode.
*/
define fluent function hasClaimLinkedToEpisode(encounter Encounter):
  exists ( [Claim] ClaimForEpisode
      where ClaimForEpisode.status = 'active'
        and ClaimForEpisode.use = 'claim'
        and exists ( ClaimForEpisode.item ClaimItem
              where exists ( ClaimItem.encounter ClaimEncounterRef
                    where exists ( [Encounter] LinkedEncounter
                          where ClaimEncounterRef.references ( LinkedEncounter )
                            and LinkedEncounter.period overlaps Interval[start of encounter.period - 1 day, end of encounter.period] ) ) ) )

define "Ischemic Stroke Encounters With Discharge Disposition":
  "Ischemic Stroke Encounter" IschemicStrokeEncounter
  let DischDisp: IschemicStrokeEncounter.hospitalization.dischargeDisposition
  	where  DischDisp in "Discharge To Acute Care Facility"
		or DischDisp in "Left Against Medical Advice"
		or DischDisp in "Patient Expired"
		or DischDisp in "Discharged to Home for Hospice Care"
		or DischDisp in "Discharged to Health Care Facility for Hospice Care"			

define "Encounter With Comfort Measures During Hospitalization":
  "Ischemic Stroke Encounter" IschemicStrokeEncounter
    with "Intervention Comfort Measures" ComfortMeasure
     such that Coalesce(start of ComfortMeasure.performed.toInterval(), ComfortMeasure.authoredOn) during IschemicStrokeEncounter.hospitalizationWithObservation()

define "Intervention Comfort Measures":
  ( ["ServiceRequest": "Comfort Measures"] ComfortCare
    where ComfortCare.status in { 'active', 'completed', 'on-hold' }
      and ComfortCare.intent in { 'order', 'original-order', 'reflex-order', 'filler-order', 'instance-order' }
  )  
  union ( ["Procedure": "Comfort Measures"] ComfortCarePerformed
        where ComfortCarePerformed.status in { 'completed', 'in-progress' }
  )
  
define fluent function calendarDayOfOrDayAfter(StartValue DateTime):
  Interval [date from (StartValue), date from (StartValue) + 1 day]
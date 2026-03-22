---- MODULE ReactiveMeshAuthZ ----
EXTENDS Naturals, Sequences, TLC

CONSTANTS Ids, TerminationBound

VARIABLES streamState, revoked

vars == <<streamState, revoked>>

States == {"New", "Active", "RevokedPending", "Terminated", "Denied"}

Init ==
  /\ streamState \in [Ids -> States]
  /\ revoked = {}
  /\ \A id \in Ids: streamState[id] = "New"

OpenStream(id) ==
  /\ id \in Ids
  /\ ~ (id \in revoked)
  /\ streamState[id] \in {"New", "Terminated"}
  /\ streamState' = [streamState EXCEPT ![id] = "Active"]
  /\ revoked' = revoked

Revoke(id) ==
  /\ id \in Ids
  /\ ~(id \in revoked)
  /\ revoked' = revoked \cup {id}
  /\ streamState' = [streamState EXCEPT ![id] = IF @ = "Active" THEN "RevokedPending" ELSE "Denied"]

Terminate(id) ==
  /\ id \in Ids
  /\ streamState[id] = "RevokedPending"
  /\ streamState' = [streamState EXCEPT ![id] = "Terminated"]
  /\ revoked' = revoked

DenyNew(id) ==
  /\ id \in revoked
  /\ streamState[id] \in {"New", "Denied", "Terminated"}
  /\ streamState' = [streamState EXCEPT ![id] = "Denied"]
  /\ revoked' = revoked

NoOp ==
  /\ UNCHANGED <<streamState, revoked>>

Next ==
  \E id \in Ids:
    OpenStream(id) \/ Revoke(id) \/ Terminate(id) \/ DenyNew(id)
  \/ NoOp

Spec == Init /\ [][Next]_<<streamState, revoked>>
Liveness ==
  \A id \in Ids: WF_vars(Terminate(id))

SpecWithFairness == Spec /\ Liveness

RevokedEventuallyTerminated ==
  \A id \in Ids:
    [](id \in revoked /\ streamState[id] = "RevokedPending" => <>(streamState[id] = "Terminated"))

NoNewStreamAfterRevoke ==
  \A id \in Ids:
    [](id \in revoked => streamState[id] # "Active")

NoMatchingEventNoTermination ==
  \A id \in Ids:
    []((~(id \in revoked)) => ~(streamState[id] = "Terminated"))

====
